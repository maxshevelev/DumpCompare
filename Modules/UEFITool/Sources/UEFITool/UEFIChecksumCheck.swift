import Foundation
import UEFIImage

/// A checksum a node of a known kind carries, so a caller can say which one of
/// them is wrong without looking at byte offsets.
public enum UEFIChecksumField: String, Hashable, Sendable {
    /// A volume's 16-bit header checksum (§3.3).
    case volume
    /// An FFS file's header checksum (§5.4).
    case fileHeader
    /// An FFS file's body checksum, or its fixed value when the checksum
    /// attribute bit is unset (§5.4).
    case fileBody
    /// A microcode image's checksum dword (§7.1).
    case microcode

    /// What to call the field where the panel has to name it — the pointer's
    /// reading of a flagged row's warning, which says which checksum is wrong
    /// rather than only that one is.
    public var label: String {
        switch self {
        case .volume: return "volume header"
        case .fileHeader: return "file header"
        case .fileBody: return "file body"
        case .microcode: return "microcode"
        }
    }
}

/// Tells whether a node's checksums are right, using the same `UEFIChecksums`
/// repairs that would fix them — one source for validity, the red flag and the
/// Fix write (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// Nothing here reads diagnostics: the module's unit-test fixtures build images
/// by hand and carry none, and `UEFIChecksums.repairs` yields the invalid
/// fields *and* the exact bytes a fix would write.
public enum UEFIChecksumCheck {
    /// The revision of the volume a node lives in, or nil when the node has no
    /// volume ancestor (a hand-built fixture, or a node under nothing but a
    /// region). A volume's subtype is its revision (`VolumeParser` stores it
    /// there).
    ///
    /// Only an FFS file's body checksum needs it: when the file's checksum
    /// attribute bit is unset the body must be the fixed value of the volume's
    /// revision — `0x5A` for revision 1, `0xAA` for revision 2. Volumes and
    /// microcode check themselves, so their repair never asks.
    public static func volumeRevision(of node: UEFINode, in image: UEFIImage) -> UInt8? {
        // The innermost volume covering the node: `allNodes` runs outermost
        // first, so the last containing volume is the deepest one.
        image.allNodes.reversed().first { candidate in
            candidate.kind == .volume && candidate.range.contains(node.header.lowerBound)
        }?.subtype
    }

    /// The writes that put a node's checksums right, or [] when they already
    /// are. Dispatches on `node.kind` to the matching `UEFIChecksums.repairs`.
    ///
    /// A `.file` with no volume ancestor — a volume-less hand-built fixture —
    /// validates its header only: its body's fixed value needs the volume
    /// revision, which parser output always has.
    public static func repairs(
        for node: UEFINode,
        volumeRevision: UInt8?,
        in reader: ImageReader
    ) -> [ChecksumRepair] {
        switch node.kind {
        case .volume:
            return UEFIChecksums.repairs(forVolume: node, in: reader)
        case .microcode:
            return UEFIChecksums.repairs(forMicrocode: node, in: reader)
        case .file:
            guard let volumeRevision else {
                return fileHeaderRepairs(for: node, in: reader)
            }
            return UEFIChecksums.repairs(for: node, volumeRevision: volumeRevision, in: reader)
        default:
            return []
        }
    }

    /// The writes that put every node's checksum right, keyed by node id. One
    /// pass over the three kinds that carry checksums, kept so the panel can
    /// both flag a node *and* say what each wrong checksum should be — the
    /// repair's own bytes are the value a Fix writes, and the bytes a detail
    /// row quotes as "should be" (§3.3, §5.4, §7.1). Empty for a node whose
    /// checksums are all right (or unreadable).
    ///
    /// `only`, when given, is the set of node ids worth reading — everything
    /// else in the image is left alone. That is what lets a panel over a
    /// lazily-materialized tree check each branch once, as it opens, instead
    /// of re-reading every file body it has ever seen each time one more
    /// branch appears.
    public static func repairs(
        in image: UEFIImage,
        only: Set<NodeID>? = nil,
        reader: ImageReader
    ) -> [NodeID: [ChecksumRepair]] {
        var result: [NodeID: [ChecksumRepair]] = [:]
        for node in image.allNodes {
            guard node.kind == .volume || node.kind == .file || node.kind == .microcode
            else { continue }
            if let only, !only.contains(node.id) { continue }
            let revision = node.kind == .file ? volumeRevision(of: node, in: image) : nil
            let nodeRepairs = repairs(for: node, volumeRevision: revision, in: reader)
            guard !nodeRepairs.isEmpty else { continue }
            result[node.id] = nodeRepairs
        }
        return result
    }

    /// Which checksum field of every node is wrong, keyed by node id — the
    /// shape the panel's warning and icon key on. Derived from the one heavy
    /// pass above, so a caller that wants both pays for the body reads once.
    public static func badFields(
        in image: UEFIImage,
        reader: ImageReader
    ) -> [NodeID: Set<UEFIChecksumField>] {
        fields(of: repairs(in: image, reader: reader), in: image)
    }

    /// The checksum fields a set of per-node repairs stand for, keyed by node
    /// id — the light mapping of `repairs(in:)` a caller that already has them
    /// applies without a second pass over the bytes.
    public static func fields(
        of repairsByNode: [NodeID: [ChecksumRepair]],
        in image: UEFIImage
    ) -> [NodeID: Set<UEFIChecksumField>] {
        var result: [NodeID: Set<UEFIChecksumField>] = [:]
        for node in image.allNodes {
            if let repairs = repairsByNode[node.id] {
                result[node.id] = fields(of: repairs, for: node)
            }
        }
        return result
    }

    /// The checksum fields the repairs of one node stand for. A volume's and a
    /// microcode image's every repair is their one checksum; a file's two
    /// checksum bytes sit at fixed offsets, so which byte was written tells
    /// header from body apart.
    public static func fields(
        of repairs: [ChecksumRepair],
        for node: UEFINode
    ) -> Set<UEFIChecksumField> {
        let headerOffset = node.header.lowerBound
        var fields: Set<UEFIChecksumField> = []
        for repair in repairs {
            switch node.kind {
            case .volume:
                fields.insert(.volume)
            case .microcode:
                fields.insert(.microcode)
            case .file:
                if repair.offset == headerOffset + 0x11 {
                    fields.insert(.fileBody)
                } else {
                    fields.insert(.fileHeader)
                }
            default:
                break
            }
        }
        return fields
    }

    /// A volume-less file's header checksum, mirroring the header half of
    /// `UEFIChecksums.repairs(for:volumeRevision:in:)` (§5.4). Kept here rather
    /// than refactored into the package because parser output always has the
    /// volume — this path exists only so a hand-built fixture can be checked
    /// for its header alone.
    private static func fileHeaderRepairs(
        for file: UEFINode,
        in reader: ImageReader
    ) -> [ChecksumRepair] {
        let h = file.header.lowerBound
        guard let storedHeader = reader.uint8(at: h + 0x10),
              let storedBody = reader.uint8(at: h + 0x11),
              let state = reader.uint8(at: h + 0x17),
              let headerBytes = reader.bytes(file.header)
        else { return [] }
        let sum = Checksums.sum8(headerBytes) &- storedHeader &- storedBody &- state
        let computed = 0 &- sum
        return computed == storedHeader
            ? []
            : [ChecksumRepair(offset: h + 0x10, bytes: [computed])]
    }
}
