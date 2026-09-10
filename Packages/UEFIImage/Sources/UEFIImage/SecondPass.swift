import Foundation

/// `X86_RESET_VECTOR_DATA`, at fixed physical addresses inside the Volume Top
/// File (§5.7).
///
/// The last forty-eight bytes of the address space, which is where an x86 starts
/// executing. Worth reading because it is the one place that says, in the
/// image's own words, where it thinks it is loaded — and an image that disagrees
/// with itself here is an image somebody's tool has moved.
public struct ResetVector: Equatable, Sendable {
    /// Where the structure begins in the file.
    public var offset: UInt64
    /// Eight bytes at `0xFFFFFFD0`.
    public var apEntryVector: [UInt8]
    /// `0xFFFFFFE0`.
    public var peiCoreEntryPoint: UInt32
    /// Eight bytes at `0xFFFFFFF0` — the first instruction the processor runs.
    public var resetVector: [UInt8]
    /// `0xFFFFFFF8`.
    public var apStartupSegment: UInt32
    /// `0xFFFFFFFC`.
    public var bootFvBaseAddress: UInt32

    /// What EDK2 leaves in a field it did not fill in.
    public static let placeholder: UInt32 = 0x1234_5678

    public static let size: UInt64 = 0x30
    /// The address the structure starts at.
    public static let address: UInt64 = 0xFFFF_FFD0

    /// Whether a field holds an address at all, as opposed to the placeholder
    /// EDK2 leaves behind or an erased word. A caller following one of these
    /// without asking ends up somewhere that was never meant to be anywhere.
    public static func isFilledIn(_ field: UInt32) -> Bool {
        field != placeholder && field != 0 && field != .max
    }
}

extension Parser {
    /// `Sendable` because the VTF descent runs off the main actor and hands
    /// this back to `LazyUEFITree` when it lands.
    struct SecondPass: Sendable {
        var addressDiff: UInt64?
        var resetVector: ResetVector?
    }

    /// Everything that needs an address rather than an offset (§10).
    ///
    /// It can only run once the tree exists, because the one thing that ties
    /// this image to an address is a node the first pass has to find: the last
    /// Volume Top File, whose final byte is mapped at `0xFFFFFFFF`. Without it
    /// every address in the image is unknowable, and the honest answer is to
    /// say so rather than to assume the image is a full flash dump.
    func runSecondPass(_ roots: inout [UEFINode]) -> SecondPass {
        // No VTF is not a defect: a dump of one BIOS region, or of an EC, has
        // none, and `addressDiff` staying nil is the whole of what that means.
        guard let vtf = lastVolumeTopFile(in: roots) else { return SecondPass() }
        let second = secondPass(anchoredOn: vtf)
        // The VTF is the anchor for every address in the image, so moving it
        // moves everything (§11).
        if second.addressDiff != nil { markFixed(&roots, at: vtf.range.lowerBound) }
        return second
    }

    /// The mapping a given Volume Top File fixes, and what can be read with it.
    /// Separated from finding one because there are two ways to find one — the
    /// walk above, and the tail look below.
    func secondPass(anchoredOn vtf: UEFINode) -> SecondPass {
        let top = vtf.range.upperBound
        guard top <= 0x1_0000_0000 else {
            note(.addressesUnknown, at: vtf.range.lowerBound)
            return SecondPass()
        }
        let addressDiff = 0x1_0000_0000 - top
        return SecondPass(
            addressDiff: addressDiff,
            resetVector: readResetVector(addressDiff: addressDiff, within: vtf)
        )
    }

    /// The Volume Top File found where the format says it has to be, rather
    /// than by walking to it.
    ///
    /// Its last byte is the last byte of the address space (§5.7), so an image
    /// mapped flush to the top of it ends *with* the VTF. Looking for the
    /// file's GUID in the last few tens of kilobytes is a couple of reads;
    /// walking to it means scanning the whole BIOS region for volume
    /// signatures and then walking the last volume's files, which on a 24 MiB
    /// dump measured half a second — and every panel that wants an address
    /// waits for it.
    ///
    /// Nil when the tail holds no VTF whose size lands it exactly at the end:
    /// an image mapped some other way, a region cut out of one, a dump with
    /// bytes appended. The caller then walks, and gets the same answer the
    /// slow way.
    func volumeTopFileInTail(window: UInt64 = 0x10000) -> UEFINode? {
        let count = reader.count
        guard count > FFS.headerSize else { return nil }
        let start = count > window ? count - window : 0
        guard let bytes = reader.bytes(start..<count) else { return nil }

        let guid = KnownGUIDs.volumeTopFile.bytes
        var found: UEFINode?
        var index = 0
        while index + guid.count <= bytes.count {
            defer { index += 1 }
            guard Array(bytes[index..<(index + guid.count)]) == guid else { continue }
            let header = start + UInt64(index)
            // The size field of the FFS header this GUID would be the name of
            // (§5.1). It has to land the file's last byte on the image's.
            guard let size = reader.uint24(at: header + 0x14),
                  UInt64(size) > FFS.headerSize,
                  header + UInt64(size) == count
            else { continue }
            found = UEFINode(
                kind: .file,
                name: KnownGUIDs.name(of: KnownGUIDs.volumeTopFile) ?? "Volume Top File",
                guid: KnownGUIDs.volumeTopFile,
                header: header..<(header + FFS.headerSize),
                body: (header + FFS.headerSize)..<count,
                isFixed: true
            )
        }
        return found
    }

    /// The *last* one: an image can hold several, and only the last is at the
    /// top of the address space (§5.7). A compressed one is no use — its
    /// address is wherever the decompressor put it.
    private func lastVolumeTopFile(in roots: [UEFINode]) -> UEFINode? {
        roots.flatMap(\.flattened)
            .filter { $0.kind == .file && $0.guid == KnownGUIDs.volumeTopFile && !$0.isCompressed }
            .max { $0.range.upperBound < $1.range.upperBound }
    }

    private func readResetVector(addressDiff: UInt64, within vtf: UEFINode) -> ResetVector? {
        let offset = ResetVector.address - addressDiff
        // Inside the VTF, or it is not this image's reset vector.
        guard offset >= vtf.range.lowerBound,
              offset + ResetVector.size <= vtf.range.upperBound,
              let apEntryVector = reader.bytes(at: offset, count: 8),
              let peiCoreEntryPoint = reader.uint32(at: offset + 0x10),
              let resetVector = reader.bytes(at: offset + 0x20, count: 8),
              let apStartupSegment = reader.uint32(at: offset + 0x28),
              let bootFvBaseAddress = reader.uint32(at: offset + 0x2C)
        else {
            note(.truncated(.resetVector), at: vtf.range.lowerBound)
            return nil
        }
        return ResetVector(
            offset: offset,
            apEntryVector: apEntryVector,
            peiCoreEntryPoint: peiCoreEntryPoint,
            resetVector: resetVector,
            apStartupSegment: apStartupSegment,
            bootFvBaseAddress: bootFvBaseAddress
        )
    }

    /// Marks the node starting at `offset`, wherever it is in the tree. By
    /// offset and not by id, because ids are stamped only once the tree is
    /// finished and the second pass runs before that.
    func markFixed(_ nodes: inout [UEFINode], at offset: UInt64) {
        for index in nodes.indices {
            if nodes[index].range.lowerBound == offset {
                nodes[index].isFixed = true
                return
            }
            if nodes[index].range.contains(offset) {
                markFixed(&nodes[index].children, at: offset)
                return
            }
        }
    }
}
