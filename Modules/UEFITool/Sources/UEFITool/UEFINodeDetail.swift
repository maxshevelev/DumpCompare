import Foundation
import UEFIImage

/// One label/value row in the detail list.
public struct UEFIDetailField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// A value that reads as a problem — a checksum that does not check out.
    /// The controller colours just this row's value with it; everything else
    /// stays as it is.
    public var isProblem: Bool

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
        self.isProblem = false
    }

    public init(_ label: String, _ value: String, isProblem: Bool) {
        self.label = label
        self.value = value
        self.isProblem = isProblem
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
/// tables are `UEFIImage`'s, not re-derived here.
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

        case .uefiImage:
            // An empty header and nothing of its own to read: the wrapper's
            // only contribution is its common geometry fields.
            break

        case .intelImage:
            // The image node is the whole file, and its bytes are the flash
            // descriptor that maps it. The header of the descriptor carries the
            // map (FLMAP0-2, at `0x14`) whose counters say how many chips,
            // regions, masters and strap dwords the board has — the block the
            // reference parser prints on its "Intel image" root. The first
            // three are stored minus one; the two strap counts are not (§2.1).
            if let map0 = reader.uint32(at: h + 0x14) {
                fields.append(.init("Flash chips", "\(((map0 >> 8) & 0x3) + 1)"))
                fields.append(.init("Regions", "\(((map0 >> 24) & 0x7) + 1)"))
            }
            if let map1 = reader.uint32(at: h + 0x18) {
                fields.append(.init("Masters", "\(((map1 >> 8) & 0x3) + 1)"))
                fields.append(.init("PCH straps", "\((map1 >> 24) & 0xFF)"))
            }
            if let map2 = reader.uint32(at: h + 0x1C) {
                fields.append(.init("PROC straps", "\((map2 >> 8) & 0xFF)"))
            }

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

        case .vssStore:
            // A VSS store's header is a signature and size, then the format,
            // state and two reserved words that describe the store (§9).
            if let format = reader.uint8(at: h + 8) { fields.append(.init("Format", hex(format))) }
            if let state = reader.uint8(at: h + 9) { fields.append(.init("State", hex(state))) }
            if let reserved = reader.uint16(at: h + 10) { fields.append(.init("Reserved", hex(reserved))) }
            if let reserved1 = reader.uint32(at: h + 12) { fields.append(.init("Reserved1", hex(reserved1))) }

        case .vss2Store:
            // A VSS2 store is the same four fields, after its 16-byte store
            // GUID and size (§9).
            if let format = reader.uint8(at: h + 20) { fields.append(.init("Format", hex(format))) }
            if let state = reader.uint8(at: h + 21) { fields.append(.init("State", hex(state))) }
            if let reserved = reader.uint16(at: h + 22) { fields.append(.init("Reserved", hex(reserved))) }
            if let reserved1 = reader.uint32(at: h + 24) { fields.append(.init("Reserved1", hex(reserved1))) }

        case .ftwStore:
            // An FTW working block checks its own header CRC32, which lives
            // next to the state byte (§9).
            if let state = reader.uint8(at: h + 20) { fields.append(.init("State", hex(state))) }
            if let crc = reader.uint32(at: h + 16) { fields.append(.init("Header CRC32", hex(crc))) }

        case .sysFStore:
            // A SysF store's header holds two unknown fields after the
            // signature; the CRC32 over the whole store is its last four bytes.
            if let unknown = reader.uint8(at: h + 4) { fields.append(.init("Unknown", hex(unknown))) }
            if let unknown1 = reader.uint32(at: h + 5) { fields.append(.init("Unknown1", hex(unknown1))) }
            // The store's CRC32 is its final four bytes, over everything before
            // them — which is where the reference parser reads it.
            if node.range.upperBound >= h + 4,
               let stored = reader.uint32(at: node.range.upperBound - 4),
               let bytes = reader.bytes(at: h, count: node.range.upperBound - 4 - h) {
                fields.append(.init("CRC32", Checksums.text(stored, valid: Checksums.crc32(bytes) == stored, digits: 8)))
            }

        case .flashMapStore:
            // A Phoenix flash map names its regions in an entry count and a
            // reserved dword before the entries themselves (§9).
            if let entries = reader.uint16(at: h + 10) { fields.append(.init("Entries", "\(entries)")) }
            if let reserved = reader.uint32(at: h + 12) { fields.append(.init("Reserved", hex(reserved))) }

        case .flashMapEntry:
            // The region GUID is the common "GUID" field; the header adds the
            // data and entry types and the region's physical layout.
            if let dataType = reader.uint16(at: h + 16) { fields.append(.init("Data type", hex(dataType))) }
            if let entryType = reader.uint16(at: h + 18) { fields.append(.init("Entry type", hex(entryType))) }
            if let size = reader.uint32(at: h + 28) { fields.append(.init("Size", hex(size))) }
            if let offset = reader.uint32(at: h + 32) { fields.append(.init("Offset", hex(offset))) }
            if let address = reader.uint64(at: h + 20) { fields.append(.init("Physical address", hex(address))) }

        case .evsaStore:
            // An EVSA store is itself an entry, type 0xEC: attributes, a
            // reserved word, and a checksum that covers its 20-byte header.
            if let attributes = reader.uint32(at: h + 8) { fields.append(.init("Attributes", hex(attributes))) }
            if let reserved = reader.uint32(at: h + 16) { fields.append(.init("Reserved", hex(reserved))) }
            if let checksum = evsaChecksum(storedAt: h + 1, covering: node.header.upperBound, reader: reader) {
                fields.append(.init("Checksum", Checksums.text(checksum.value, valid: checksum.valid)))
            }

        case .vssEntry:
            // The variable's vendor GUID is the common "GUID" field: the parser
            // set it on the node, the only place that knows where the store
            // puts it for the variable's form. State, reserved and attributes
            // follow.
            if let state = reader.uint8(at: h + 2) { fields.append(.init("State", hex(state))) }
            if let reserved = reader.uint8(at: h + 3) { fields.append(.init("Reserved", hex(reserved))) }
            if let attributes = reader.uint32(at: h + 4) {
                fields.append(.init("Attributes", bits(attributes, nvramAttributeBits)))
            }

        case .evsaEntry:
            // What the header adds depends on the entry's kind: a GUID entry
            // and a name entry carry one id word each, a data entry carries
            // both plus an attributes word. The GUID a guid entry names is the
            // common "GUID" field; the name a name entry carries is its own.
            switch node.subtype {
            case UEFITypes.Sub.guidEvsaEntry:
                if let guidId = reader.uint16(at: h + 4) { fields.append(.init("GuidId", hex(guidId))) }
            case UEFITypes.Sub.nameEvsaEntry:
                if let varId = reader.uint16(at: h + 4) { fields.append(.init("VarId", hex(varId))) }
            default:
                // A data variable, valid or not.
                if let varId = reader.uint16(at: h + 6) { fields.append(.init("VarId", hex(varId))) }
                if let guidId = reader.uint16(at: h + 4) { fields.append(.init("GuidId", hex(guidId))) }
                if let attributes = reader.uint32(at: h + 8) {
                    fields.append(.init("Attributes", bits(attributes, evsaAttributeBits)))
                }
            }
            if let checksum = evsaChecksum(storedAt: h + 1, covering: node.range.upperBound, reader: reader) {
                fields.append(.init("Checksum", Checksums.text(checksum.value, valid: checksum.valid)))
            }

        case .slicData:
            // A pubkey and a marker share their first eight bytes; what the
            // header adds after that differs (§9).
            switch node.subtype {
            case UEFITypes.Sub.pubkeySlicData:
                if let keyType = reader.uint8(at: h + 8) { fields.append(.init("Key type", hex(keyType))) }
                if let version = reader.uint8(at: h + 9) { fields.append(.init("Version", hex(version))) }
                if let algorithm = reader.uint32(at: h + 12) { fields.append(.init("Algorithm", hex(algorithm))) }
                if let bitLength = reader.uint32(at: h + 20) { fields.append(.init("Bit length", hex(bitLength))) }
                if let exponent = reader.uint32(at: h + 24) { fields.append(.init("Exponent", hex(exponent))) }
            case UEFITypes.Sub.markerSlicData:
                if let version = reader.uint32(at: h + 8) { fields.append(.init("Version", hex(version))) }
                if let oemID = reader.bytes(at: h + 12, count: 6) { fields.append(.init("OEM ID", asciiText(oemID))) }
                if let oemTableID = reader.bytes(at: h + 18, count: 8) { fields.append(.init("OEM table ID", asciiText(oemTableID))) }
                // The parser only accepts a marker whose windows flag is the
                // known value, so the reference's word for it is the value, and
                // anything else is shown as the raw number.
                if let windowsFlag = reader.uint64(at: h + 26) {
                    let value = windowsFlag == 0x2053_574F_444E_4957 ? "WINDOWS" : hex(windowsFlag)
                    fields.append(.init("Windows flag", value))
                }
                if let slicVersion = reader.uint32(at: h + 34) { fields.append(.init("SLIC version", hex(slicVersion))) }
            default: break
            }

        // FDC and CMDB stores, and a SysF variable, are read as leaves in the
        // reference: the panel has nothing to add to their common fields.
        case .fdcStore, .cmdbStore, .sysFEntry:
            break

        case .padding, .freeSpace, .nonUEFIData:
            // No header of their own: the size the common "Total" carries is
            // the whole of what there is to say.
            break
        }
        return fields
    }

    // MARK: - NVRAM header helpers

    /// The VSS variable attribute bits an entry can set, in the reference
    /// parser's order and wording. The word is the bit's meaning, not a guess:
    /// bit 31 is the Apple data-checksum flag.
    private static let nvramAttributeBits: [(UInt32, String)] = [
        (0x0000_0001, "NonVolatile"),
        (0x0000_0002, "BootService"),
        (0x0000_0004, "Runtime"),
        (0x0000_0008, "HwErrorRecord"),
        (0x0000_0010, "AuthWrite"),
        (0x0000_0020, "TimeBasedAuthWrite"),
        (0x0000_0040, "AppendWrite"),
        (0x8000_0000, "AppleChecksum"),
    ]

    /// The EVSA data-entry attribute bits. A data entry shares the VSS words
    /// and adds the extended-header bit in place of the Apple one.
    private static let evsaAttributeBits: [(UInt32, String)] = [
        (0x0000_0001, "NonVolatile"),
        (0x0000_0002, "BootService"),
        (0x0000_0004, "Runtime"),
        (0x0000_0008, "HwErrorRecord"),
        (0x0000_0010, "AuthWrite"),
        (0x0000_0020, "TimeBasedAuthWrite"),
        (0x0000_0040, "AppendWrite"),
        (0x1000_0000, "ExtendedHeader"),
    ]

    /// The stored checksum of an EVSA record and whether it counts. An EVSA
    /// record checks itself the sum-to-zero way: everything from the stored
    /// checksum byte to the record's end adds up to zero (§9). The reference
    /// parser reads that region from two bytes in, and summing from the
    /// checksum byte is the same arithmetic.
    private static func evsaChecksum(
        storedAt checksumOffset: UInt64,
        covering end: UInt64,
        reader: ImageReader
    ) -> (value: UInt8, valid: Bool)? {
        guard let stored = reader.uint8(at: checksumOffset),
              end > checksumOffset,
              let sum = Checksums.sum8(of: checksumOffset..<end, in: reader)
        else { return nil }
        return (stored, sum == 0)
    }

    /// Fixed-size bytes that hold an ASCII word: everything up to the first
    /// zero, as text. The parser's SLIC records store the OEM id and table id
    /// without a terminator, so a trailing zero is only cut when one is there.
    private static func asciiText(_ bytes: [UInt8]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: - Text

    private static func kindLabel(_ kind: UEFINodeKind) -> String {
        switch kind {
        case .capsule: return "Capsule"
        case .intelImage: return "Intel image"
        case .uefiImage: return "UEFI image"
        case .flashDescriptor: return "Flash descriptor"
        case .region: return "Region"
        case .volume: return "Volume"
        case .file: return "FFS file"
        case .section: return "Section"
        case .microcode: return "Microcode"
        // The NVRAM stores and entries read as their item-type word, matching
        // the tree's Type column.
        case .vssStore: return UEFITypes.typeName(UEFITypes.Item.vssStore.rawValue)
        case .vss2Store: return UEFITypes.typeName(UEFITypes.Item.vss2Store.rawValue)
        case .ftwStore: return UEFITypes.typeName(UEFITypes.Item.ftwStore.rawValue)
        case .fdcStore: return UEFITypes.typeName(UEFITypes.Item.fdcStore.rawValue)
        case .sysFStore: return UEFITypes.typeName(UEFITypes.Item.sysFStore.rawValue)
        case .flashMapStore: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapStore.rawValue)
        case .evsaStore: return UEFITypes.typeName(UEFITypes.Item.evsaStore.rawValue)
        case .cmdbStore: return UEFITypes.typeName(UEFITypes.Item.cmdbStore.rawValue)
        case .slicData: return UEFITypes.typeName(UEFITypes.Item.slicData.rawValue)
        case .vssEntry: return UEFITypes.typeName(UEFITypes.Item.vssEntry.rawValue)
        case .sysFEntry: return UEFITypes.typeName(UEFITypes.Item.sysFEntry.rawValue)
        case .evsaEntry: return UEFITypes.typeName(UEFITypes.Item.evsaEntry.rawValue)
        case .flashMapEntry: return UEFITypes.typeName(UEFITypes.Item.phoenixFlashMapEntry.rawValue)
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
        case .intelImage, .uefiImage:
            // Image and Intel / Image and UEFI are the type/subtype pairs
            // UEFITool names these roots; the word comes from the same table as
            // the columns.
            return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? hex(subtype)
        // An NVRAM entry and a SLIC blob carry a derived subtype; name it from
        // the table, keeping the number where the table has no word.
        case .vssEntry, .sysFEntry, .evsaEntry, .flashMapEntry, .slicData:
            return UEFITypes.subtypeName(type: node.uefiItemType, subtype) ?? hex(subtype)
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
