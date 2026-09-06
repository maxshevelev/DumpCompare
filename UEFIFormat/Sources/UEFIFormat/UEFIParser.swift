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

    public static func parse(_ source: ByteSource, limits: Limits = Limits()) -> UEFIImage {
        Parser(reader: ImageReader(source), limits: limits).run()
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

    /// What an unwritten byte looks like outside any volume. Inside one it is
    /// the volume's erase polarity that decides (§3.5); out here `0xFF` is what
    /// an erased chip reads as.
    static let defaultEmptyByte: UInt8 = 0xFF

    init(reader: ImageReader, limits: UEFIParser.Limits) {
        self.reader = reader
        self.limits = limits
    }

    func note(_ kind: UEFIDiagnostic.Kind, at offset: UInt64) {
        diagnostics.append(UEFIDiagnostic(kind, at: offset))
    }

    func run() -> UEFIImage {
        var roots = reader.count == 0 ? [] : parseTopLevel(reader.all, depth: 0)
        let second = roots.isEmpty ? SecondPass() : runSecondPass(&roots)
        return UEFIImage(
            size: reader.count,
            roots: roots,
            diagnostics: diagnostics,
            addressDiff: second.addressDiff,
            resetVector: second.resetVector
        )
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
        if let capsule = parseCapsule(at: range.lowerBound, limit: range.upperBound, depth: depth) {
            return [capsule] + padding(
                from: capsule.range.upperBound,
                to: range.upperBound,
                emptyByte: Parser.defaultEmptyByte
            )
        }
        // The signature is checked at `0x10` as well as at `0x00`: the first
        // sixteen bytes are a reserved vector, `0xFF` on x86 and a real ARM
        // reset vector on some ARM images (§1).
        if hasDescriptorSignature(at: range.lowerBound) {
            return parseIntelImage(range, depth: depth)
        }
        return scanRawArea(range, emptyByte: Parser.defaultEmptyByte, depth: depth)
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
            return padding(from: range.lowerBound, to: range.upperBound, emptyByte: emptyByte)
        }
        var nodes: [UEFINode] = []
        var claimed = range.lowerBound
        var offset = range.lowerBound
        let window: UInt64 = 1 << 20

        scan: while offset + 4 <= range.upperBound {
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
