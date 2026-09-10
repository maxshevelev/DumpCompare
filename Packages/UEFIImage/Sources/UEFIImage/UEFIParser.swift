import Foundation

/// Parses a firmware image into a tree.
///
/// Two passes (`Design/UEFI/UEFI_IMAGE_FORMAT.md`): the first builds the tree
/// purely by offsets, the second works out where the image lands in memory and
/// reads what only makes sense with an address in hand. The split is not
/// tidiness — the second pass needs a node the first pass has to find.
///
/// Nothing throws. Every level collects diagnostics and carries on with the
/// bytes it still understands, because the images worth opening a tool on are
/// the ones with something already wrong in them (§11).
public enum UEFIParser {
    public struct Limits: Sendable {
        /// Volume, file, section, volume again — real images nest eight or ten
        /// deep, and a corrupt one nests forever (§11).
        public var maxDepth: Int

        public init(maxDepth: Int = 16) {
            self.maxDepth = maxDepth
        }
    }

    /// Parses `source` into a whole tree, every container opened, in one call.
    ///
    /// The same materialization a `LazyUEFITree` performs one node at a time,
    /// driven straight through instead of on demand: build the top level, open
    /// every collapsed node under it, then work out where the image is mapped.
    /// There is no second implementation of the parse behind this — a tree
    /// built here and a tree a user expanded by hand come out of the same
    /// `TreeMaterialization` calls.
    ///
    /// Deliberately not what the app uses: opening a 16 MiB image this way
    /// takes about a second and reads every file body in it, which is exactly
    /// the wait `LazyUEFITree` exists to remove. What wants a finished tree in
    /// one value — this package's own tests, an oracle comparison against
    /// UEFITool's output — asks here.
    ///
    /// When `progress` is given it is called, on whichever thread the parse
    /// happens to be running on, with how far the scan has got through the
    /// image — monotonically, from just above 0 up to 1. Nothing calls it with
    /// the parse finished; whoever asked for progress decides what "done"
    /// means and announces it itself. It is `@Sendable` because a caller runs
    /// the parse off its main actor and must be able to hand the callback
    /// across to the scanning thread.
    public static func parse(
        _ source: ByteSource,
        limits: Limits = Limits(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> UEFIImage {
        let reader = ImageReader(source)
        let sink = progress.map { report in
            ProgressSink(total: reader.count, report: { report($0) })
        }

        let built = TreeMaterialization.roots(reader: reader, limits: limits, progress: sink)
        var roots = built.nodes
        var diagnostics = built.diagnostics
        TreeMaterialization.materializeAll(
            &roots, reader: reader, limits: limits, diagnostics: &diagnostics, progress: sink
        )

        let parser = Parser(reader: reader, limits: limits)
        let second = roots.isEmpty ? Parser.SecondPass() : parser.runSecondPass(&roots)
        return UEFIImage(
            size: reader.count,
            roots: roots,
            diagnostics: diagnostics + parser.diagnostics,
            addressDiff: second.addressDiff,
            resetVector: second.resetVector
        )
    }
}

/// The parse in progress: the reader, the limits, and the diagnostics as they
/// accumulate. A class because every level appends to one list, and threading
/// an `inout` array through a recursion this deep is how one branch's
/// diagnostics get dropped on the way back up.
final class Parser {
    let reader: ImageReader
    let limits: UEFIParser.Limits
    private(set) var diagnostics: [UEFIDiagnostic] = []
    /// Who the scan tells how far it has got, or nil to scan quietly. Shared
    /// with every other `Parser` of the same materialization, so the fractions
    /// move forward across the whole job rather than restarting per node.
    private let onProgress: ProgressSink?

    /// What an unwritten byte looks like outside any volume. Inside one it is
    /// the volume's erase polarity that decides (§3.5); out here `0xFF` is what
    /// an erased chip reads as.
    static let defaultEmptyByte: UInt8 = 0xFF

    init(
        reader: ImageReader,
        limits: UEFIParser.Limits,
        progress: ProgressSink? = nil
    ) {
        // Through a window of its own. A parser is built, used and dropped
        // inside one materialization on one thread, which is exactly the
        // lifetime a read cache needs — and the reads it makes are thousands
        // of small fields, mostly forward, which is exactly what a window
        // serves (`WindowedByteSource`).
        self.reader = ImageReader(WindowedByteSource(reader.source))
        self.limits = limits
        self.onProgress = progress
    }

    /// Reports that the scan has reached `offset`, as a fraction of the whole
    /// image.
    private func progressed(to offset: UInt64) {
        onProgress?.reached(offset)
    }

    func note(_ kind: UEFIDiagnostic.Kind, at offset: UInt64) {
        diagnostics.append(UEFIDiagnostic(kind, at: offset))
    }

    /// What kind of thing this is (§1): an update capsule, a full flash dump
    /// with an Intel descriptor, or — the common case for a dump off a chip —
    /// bytes to be searched for anything recognisable.
    ///
    /// Called again for a capsule's body, because what is inside an envelope is
    /// one of the same three things.
    func parseTopLevel(_ range: Range<UInt64>, depth: Int) -> [UEFINode] {
        guard depth < limits.maxDepth else {
            note(.recursionLimit, at: range.lowerBound)
            return []
        }
        let top: [UEFINode]
        if let capsule = parseCapsule(at: range.lowerBound, limit: range.upperBound, depth: depth) {
            // A capsule claiming less than the file holds has something after
            // it; the trailing bytes stay as padding beside it (§1.1).
            top = [capsule] + padding(
                from: capsule.range.upperBound,
                to: range.upperBound,
                emptyByte: Parser.defaultEmptyByte
            )
        } else if hasDescriptorSignature(at: range.lowerBound) {
            // The signature is checked at `0x10` as well as at `0x00`: the
            // first sixteen bytes are a reserved vector, `0xFF` on x86 and a
            // real ARM reset vector on some ARM images (§1). An Intel image is
            // already the one node over the whole file, so it is returned as is.
            return parseIntelImage(range, depth: depth)
        } else {
            // Everything else — a lone volume off a chip, a NVRAM blob, bytes
            // to be searched — is a raw-area scan, and the scan decides the
            // top of the tree (§4).
            top = scanRawArea(range, emptyByte: Parser.defaultEmptyByte, depth: depth)
        }
        // The tree has one root. Several things at the top are a file that is
        // more than one image — a run of microcode with padding around it, a
        // capsule with bytes after it — and are grouped under the UEFI image
        // node UEFITool always shows as its root; the single thing a parse
        // found is already a root of its own, and is not wrapped in an image it
        // is not.
        guard top.count > 1 else { return top }
        return [UEFINode(
            kind: .uefiImage,
            subtype: UEFITypes.Sub.uefiImage,
            name: "UEFI image",
            header: range.lowerBound..<range.lowerBound,
            body: range,
            isFixed: true,
            children: top
        )]
    }

    // MARK: - Raw areas

    /// Linear search for the structures that announce themselves (§4).
    ///
    /// A BIOS region, the body of a padding element and an image with no flash
    /// descriptor are all read the same way: walk the bytes looking for a
    /// signature, and call everything in between padding. Byte by byte, not
    /// dword by dword — nothing here guarantees a volume starts on a multiple
    /// of four, and images where one does not are common enough that the
    /// reference parser gave up on the shortcut too.
    func scanRawArea(_ range: Range<UInt64>, emptyByte: UInt8, depth: Int) -> [UEFINode] {
        guard reader.has(range), range.count >= 4 else {
            progressed(to: range.upperBound)
            return padding(from: range.lowerBound, to: range.upperBound, emptyByte: emptyByte)
        }
        var nodes: [UEFINode] = []
        var claimed = range.lowerBound
        var offset = range.lowerBound
        let window: UInt64 = 1 << 20

        scan: while offset + 4 <= range.upperBound {
            // One report per window, on the byte the window starts at: parsing
            // is mostly this scan, so how much of the image it has crossed is
            // how much of the work is done. The report goes out before the
            // window is searched rather than after — it says "reached here",
            // and a caller drawing a bar wants it filled as the scan travels.
            progressed(to: offset)
            let end = min(offset + window, range.upperBound)
            guard let bytes = reader.bytes(offset..<end) else { break }
            var index = 0
            while index + 4 <= bytes.count {
                let dword = UInt32(bytes[index])
                    | UInt32(bytes[index + 1]) << 8
                    | UInt32(bytes[index + 2]) << 16
                    | UInt32(bytes[index + 3]) << 24
                let at = offset + UInt64(index)
                if let found = element(atSignature: dword, at: at, in: range, depth: depth) {
                    nodes += padding(from: claimed, to: found.range.lowerBound, emptyByte: emptyByte)
                    nodes.append(found)
                    claimed = found.range.upperBound
                    offset = claimed
                    continue scan
                }
                index += 1
            }
            if end == range.upperBound { break }
            offset = end - 3    // so a signature straddling the window is still seen
        }

        // Whatever the last window left: the tail after the last structure, or
        // the whole range when nothing was found at all. The scan has crossed
        // the range whether or not a signature announced itself.
        progressed(to: range.upperBound)
        nodes += padding(from: claimed, to: range.upperBound, emptyByte: emptyByte)
        return nodes
    }

    /// A signature is a candidate, not a find: the four bytes turn up inside
    /// compressed data all the time, and only a header that checks out makes an
    /// element. Returning nil here means "keep scanning", and it must leave no
    /// diagnostic behind — a false candidate is not a defect in the image.
    private func element(
        atSignature dword: UInt32,
        at offset: UInt64,
        in range: Range<UInt64>,
        depth: Int
    ) -> UEFINode? {
        switch dword {
        case FV.signature:
            guard offset >= range.lowerBound + FV.signatureOffset else { return nil }
            return parseVolume(at: offset - FV.signatureOffset, limit: range.upperBound, depth: depth)
        case Microcode.headerType:
            return parseMicrocode(at: offset, limit: range.upperBound)
        default:
            return nil
        }
    }

    /// Whatever no structure claimed. Kept as a node rather than dropped: an
    /// image that cannot be put back together byte for byte is one this tool
    /// cannot honestly edit (§11).
    func padding(from start: UInt64, to end: UInt64, emptyByte: UInt8) -> [UEFINode] {
        guard start < end else { return [] }
        let range = start..<end
        let erased = reader.isFilled(range, with: emptyByte)
        return [UEFINode(
            kind: .padding,
            name: erased ? "Empty padding" : "Padding",
            range: range,
            isErased: erased
        )]
    }
}
