import Foundation
import UEFIFormat

/// One label/value row in the detail list.
public struct UEFIDetailField: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// What the panel says about the selected node, by its type
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// Built in the pure target and tested by `swift test`, so the view controller
/// lays out what this says rather than deciding anything.
public struct UEFINodeDetail: Equatable, Sendable {
    /// The node's name, or its kind when the name is empty.
    public var title: String
    public var fields: [UEFIDetailField]

    public static let empty = UEFINodeDetail(title: "", fields: [])
}

/// Reads the selected node's header and says what it is
/// (`Design/UEFI_STRUCTURE_TOOL.md`).
///
/// The fields come from the bytes, through the same `ImageReader` the parser
/// used: a field the header does not hold is absent, not guessed, and the name
/// tables are `UEFIFormat`'s, not re-derived here.
public enum UEFIDetail {
    public static func build(
        for node: UEFINode,
        image: UEFIImage,
        reader: ImageReader
    ) -> UEFINodeDetail {
        var fields = commonFields(for: node, image: image)
        fields += headerFields(for: node, reader: reader)
        let title = node.name.isEmpty ? kindLabel(node.kind) : node.name
        return UEFINodeDetail(title: title, fields: fields)
    }

    // MARK: - The fields every node has

    private static func commonFields(for node: UEFINode, image: UEFIImage) -> [UEFIDetailField] {
        var fields: [UEFIDetailField] = []
        fields.append(.init("Kind", kindLabel(node.kind)))
        if node.subtype != nil {
            fields.append(.init("Type", typeText(node)))
        }
        if let guid = node.guid {
            fields.append(.init("GUID", guidText(guid)))
        }
        fields.append(.init("Header", rangeText(node.header)))
        fields.append(.init("Body", rangeText(node.body)))
        if !node.tail.isEmpty {
            fields.append(.init("Tail", rangeText(node.tail)))
        }
        fields.append(.init("Total", rangeText(node.range)))

        var flags: [String] = []
        if node.isFixed { flags.append("fixed") }
        if node.isCompressed { flags.append("compressed") }
        if node.isErased { flags.append("erased") }
        if !flags.isEmpty {
            fields.append(.init("Flags", flags.joined(separator: ", ")))
        }

        // A compressed node's address means nothing — the decompressor puts it
        // wherever it likes — so the one thing worth showing is skipped there.
        if !node.isCompressed,
           let address = image.address(forOffset: node.range.lowerBound) {
            fields.append(.init("Address", hex(address)))
        }
        return fields
    }

    // MARK: - What the node's header adds

    private static func headerFields(for node: UEFINode, reader: ImageReader) -> [UEFIDetailField] {
        let h = node.header.lowerBound
        var fields: [UEFIDetailField] = []
        switch node.kind {
        case .volume:
            if let length = reader.uint64(at: h + 0x20) { fields.append(.init("Length", hex(length))) }
            if let signature = reader.uint32(at: h + 0x28) { fields.append(.init("Signature", hex(signature))) }
            if let attributes = reader.uint32(at: h + 0x2C) {
                fields.append(.init("Attributes", bits(attributes, [(0x0000_0800, "Erase polarity")])))
            }
            if let headerLength = reader.uint16(at: h + 0x30) { fields.append(.init("Header length", hex(headerLength))) }
            if let checksum = reader.uint16(at: h + 0x32) { fields.append(.init("Checksum", hex(checksum))) }
            if let extOffset = reader.uint16(at: h + 0x34) { fields.append(.init("Ext. header", hex(extOffset))) }
            if let revision = reader.uint8(at: h + 0x37) { fields.append(.init("Revision", "\(revision)")) }

        case .file:
            // The name GUID is the common "GUID" field and the type is the
            // common "Type" field; what the header adds is the rest.
            if let attributes = reader.uint8(at: h + 0x13) {
                fields.append(.init(
                    "Attributes",
                    bits(attributes, [(0x01, "Tail / large"), (0x04, "Fixed"), (0x40, "Checksum")])
                ))
            }
            // A large file keeps its size in a 64-bit field after the base
            // header and leaves the three-byte one at zero (§5.2).
            if let size = reader.uint24(at: h + 0x14), size != 0 {
                fields.append(.init("Size", hex(size)))
            } else if let largeSize = reader.uint64(at: h + 0x18) {
                fields.append(.init("Size", hex(largeSize)))
            }
            if let state = reader.uint8(at: h + 0x17) {
                fields.append(.init("State", bits(state, [(0x80, "Erase polarity")])))
            }
            if let headerChecksum = reader.uint8(at: h + 0x10) { fields.append(.init("Header checksum", hex(headerChecksum))) }
            if let bodyChecksum = reader.uint8(at: h + 0x11) { fields.append(.init("Body checksum", hex(bodyChecksum))) }

        case .section:
            // The type is the common "Type" field; the header adds the size.
            // An extended-size section leaves the three-byte field at the
            // marker and keeps the real one in 32 bits (§6).
            if let size = reader.uint24(at: h) {
                if size == 0xFF_FFFF, let extended = reader.uint32(at: h + 0x04) {
                    fields.append(.init("Size", hex(extended)))
                } else {
                    fields.append(.init("Size", hex(size)))
                }
            }

        case .microcode:
            // The header type is a constant of a valid Intel microcode, so it
            // is read straight from the bytes; the rest comes back as the
            // validated header, whose date is BCD the reader would otherwise
            // have to unpack.
            if let headerType = reader.uint32(at: h) { fields.append(.init("Header type", hex(headerType))) }
            if let header = MicrocodeHeader.read(at: h, in: reader) {
                fields.append(.init("Update revision", hex(header.updateRevision)))
                fields.append(.init("Date", header.date))
                fields.append(.init("Processor signature", hex(header.processorSignature)))
                fields.append(.init("Checksum", hex(header.checksum)))
                // The loader revision is checked by the reader but not kept on
                // the validated header, so it comes straight off the bytes.
                if let loaderRevision = reader.uint32(at: h + 0x14) {
                    fields.append(.init("Loader revision", hex(loaderRevision)))
                }
                fields.append(.init("Platform IDs", hex(header.platformIDs)))
                fields.append(.init("Data size", hex(header.dataSize)))
                fields.append(.init("Total size", hex(header.totalSize)))
            }

        case .capsule:
            // The capsule GUID is the common "GUID" field.
            if let headerSize = reader.uint32(at: h + 0x10) { fields.append(.init("Header size", hex(headerSize))) }
            if let flags = reader.uint32(at: h + 0x14) { fields.append(.init("Flags", hex(flags))) }
            if let imageSize = reader.uint32(at: h + 0x18) { fields.append(.init("Image size", hex(imageSize))) }

        case .flashDescriptor:
            if let signature = reader.uint32(at: h + 0x10) { fields.append(.init("Signature", hex(signature))) }
            if let map = reader.uint32(at: h + 0x14) { fields.append(.init("FLMAP", hex(map))) }
            if let version = reader.uint32(at: h + 0x20) { fields.append(.init("Version", hex(version))) }

        case .region:
            // The descriptor's table keeps base and limit in 4 KiB units; the
            // type is the common "Type" field.
            fields.append(.init("Base (4 KiB)", hex(node.range.lowerBound >> 12)))
            if node.range.upperBound > 0 {
                fields.append(.init("Limit (4 KiB)", hex((node.range.upperBound - 1) >> 12)))
            }

        case .padding, .freeSpace, .nonUEFIData:
            // No header of their own: the size the common "Total" carries is
            // the whole of what there is to say.
            break
        }
        return fields
    }

    // MARK: - Text

    private static func kindLabel(_ kind: UEFINodeKind) -> String {
        switch kind {
        case .capsule: return "Capsule"
        case .flashDescriptor: return "Flash descriptor"
        case .region: return "Region"
        case .volume: return "Volume"
        case .file: return "FFS file"
        case .section: return "Section"
        case .microcode: return "Microcode"
        case .padding: return "Padding"
        case .freeSpace: return "Free space"
        case .nonUEFIData: return "Non-UEFI data"
        }
    }

    /// The type byte, named by the kind that gives it a meaning. The name
    /// carries the code when there is no name — `FFS.typeName` and
    /// `Section.typeName` fall back to `File type 0xNN` / `Section type 0xNN` —
    /// so a known type is a word and an unknown one is its number.
    private static func typeText(_ node: UEFINode) -> String {
        guard let subtype = node.subtype else { return "" }
        switch node.kind {
        case .file: return UEFITypeNames.file(subtype)
        case .section: return UEFITypeNames.section(subtype)
        case .volume: return "Revision \(subtype)"
        case .region:
            // The region label has no number in it, so the code goes with it.
            return FlashRegionType(rawValue: Int(subtype)).map { "\($0.label) · \(hex(subtype))" } ?? hex(subtype)
        default: return hex(subtype)
        }
    }

    private static func guidText(_ guid: EFIGUID) -> String {
        if let known = KnownGUIDs.name(of: guid) {
            return "\(guid) (\(known))"
        }
        return guid.description
    }

    private static func rangeText(_ range: Range<UInt64>) -> String {
        guard !range.isEmpty else { return "—" }
        return "\(hex(range.lowerBound)) · \(hex(range.count)) bytes"
    }

    /// The hex value, with the well-known bits named when they are set.
    private static func bits<T: FixedWidthInteger>(_ value: T, _ names: [(T, String)]) -> String {
        let set = names.filter { value & $0.0 != 0 }.map(\.1)
        var text = hex(value)
        if !set.isEmpty { text += " (" + set.joined(separator: ", ") + ")" }
        return text
    }

    private static func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
    }
}
