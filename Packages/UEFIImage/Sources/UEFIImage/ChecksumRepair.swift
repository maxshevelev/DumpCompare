import Foundation

/// Bytes that have to be written to put a structure's checksums back in order.
///
/// The reason this package produces writes rather than performing them: nothing
/// here touches a file. A tool-module turns these into a `ToolTransaction`, and
/// the transaction is what makes the whole repair one undoable step — the four
/// scattered writes of a FIT edit and the checksums they invalidate landing
/// together or not at all (`Design/TOOL_MODULES_PLAN.md`).
public struct ChecksumRepair: Equatable, Sendable {
    public var offset: UInt64
    public var bytes: [UInt8]

    public init(offset: UInt64, bytes: [UInt8]) {
        self.offset = offset
        self.bytes = bytes
    }
}

/// Recomputing what an edit invalidates.
///
/// Every level of this format checks itself, and the checks nest: change a
/// file's body and the file's body checksum is wrong; change its header and the
/// header checksum is wrong. The volume above it does *not* care — its checksum
/// covers only its own header (§3.3) — which is the one mercy in this format and
/// the reason this cascade is two steps and not ten.
public enum UEFIChecksums {
    /// What to write after a file's body or header changed (§5.4). Returns only
    /// what actually differs, so an empty result means nothing needs fixing.
    public static func repairs(
        for file: UEFINode,
        volumeRevision: UInt8,
        in reader: ImageReader
    ) -> [ChecksumRepair] {
        guard file.kind == .file,
              let storedHeader = reader.uint8(at: file.header.lowerBound + 0x10),
              let storedBody = reader.uint8(at: file.header.lowerBound + 0x11),
              let attributes = reader.uint8(at: file.header.lowerBound + 0x13),
              let state = reader.uint8(at: file.header.lowerBound + 0x17),
              let headerBytes = reader.bytes(file.header)
        else { return [] }

        var repairs: [ChecksumRepair] = []

        // The body checksum first, though the order does not matter: the header
        // sum excludes both checksum bytes, so neither depends on the other.
        if !file.body.isEmpty {
            let computed: UInt8
            if attributes & FFS.checksumBit != 0 {
                guard let sum = Checksums.sum8(of: file.body, in: reader) else { return [] }
                computed = 0 &- sum
            } else {
                computed = volumeRevision == 1 ? FFS.fixedChecksum : FFS.fixedChecksum2
            }
            if computed != storedBody {
                repairs.append(
                    ChecksumRepair(offset: file.header.lowerBound + 0x11, bytes: [computed])
                )
            }
        }

        let sum = Checksums.sum8(headerBytes) &- storedHeader &- storedBody &- state
        let computed = 0 &- sum
        if computed != storedHeader {
            repairs.append(
                ChecksumRepair(offset: file.header.lowerBound + 0x10, bytes: [computed])
            )
        }
        return repairs
    }

    /// What to write after a volume header changed (§3.3). The sum covers
    /// `HeaderLength` bytes and not the extended header, so this reads the
    /// length back out of the header rather than trusting the node's.
    public static func repairs(
        forVolume volume: UEFINode,
        in reader: ImageReader
    ) -> [ChecksumRepair] {
        let offset = volume.header.lowerBound
        guard volume.kind == .volume,
              let headerLength = reader.uint16(at: offset + 0x30),
              let stored = reader.uint16(at: offset + UInt64(FV.checksumOffset)),
              var bytes = reader.bytes(at: offset, count: UInt64(headerLength))
        else { return [] }

        bytes[FV.checksumOffset] = 0
        bytes[FV.checksumOffset + 1] = 0
        guard let computed = Checksums.checksum16(bytes), computed != stored else { return [] }
        return [ChecksumRepair(
            offset: offset + UInt64(FV.checksumOffset),
            bytes: [
                UInt8(truncatingIfNeeded: computed),
                UInt8(truncatingIfNeeded: computed >> 8)
            ]
        )]
    }

    /// What to write after a microcode image changed (§7.1): the field that
    /// brings the sum of every dword back to zero.
    public static func repairs(
        forMicrocode microcode: UEFINode,
        in reader: ImageReader
    ) -> [ChecksumRepair] {
        let offset = microcode.header.lowerBound
        guard microcode.kind == .microcode,
              let stored = reader.uint32(at: offset + 0x10),
              let sum = Checksums.sum32(of: microcode.range, in: reader),
              sum != 0
        else { return [] }
        let computed = stored &- sum
        return [ChecksumRepair(
            offset: offset + 0x10,
            bytes: (0..<4).map { UInt8(truncatingIfNeeded: computed >> (8 * $0)) }
        )]
    }
}
