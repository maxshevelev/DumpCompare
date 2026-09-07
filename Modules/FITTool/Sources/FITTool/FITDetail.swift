import Foundation
import UEFIImage

/// One label/value row in the detail list.
public struct FITDetailField: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// What the panel says about the selected row: the row's own sixteen bytes,
/// and what its address leads to, read rather than assumed.
///
/// Built in the pure target and tested by `swift test`, so the view controller
/// lays out what this says rather than deciding anything.
public struct FITRowDetail: Equatable, Sendable {
    /// The row's place and type, named the way the zones name it.
    public var title: String
    public var fields: [FITDetailField]

    public static let empty = FITRowDetail(title: "", fields: [])
}

/// Reads a row and says what it is, field by field.
///
/// The entry's own sixteen bytes come straight off the model, and what the row
/// points at was already read when the table was — a microcode header, an
/// Index/IO descriptor, a named region — so this reads nothing new: it only
/// puts what was found into the shape the panel draws.
public enum FITDetail {
    public static func build(for row: FITRow) -> FITRowDetail {
        let entry = row.entry
        var fields = entryFields(of: entry)
        fields += targetFields(of: row)
        return FITRowDetail(
            title: "#\(entry.index) \(FIT.typeName(entry.type))",
            fields: fields
        )
    }

    // MARK: - The sixteen bytes of the row itself

    private static func entryFields(of entry: FITEntry) -> [FITDetailField] {
        var fields: [FITDetailField] = [
            .init("Offset", hex(entry.offset, digits: 8)),
            .init("Address", entry.isHeader ? "_FIT_" : hex(entry.address, digits: 8))
        ]
        fields.append(.init("Size", sizeText(entry)))
        fields.append(.init("Reserved", reservedText(entry)))
        fields.append(.init("Version", entry.versionText))
        fields.append(.init("Type", "\(FIT.typeName(entry.type)) · \(hex(entry.type, digits: 2))"))
        fields.append(.init("Checksum valid", entry.checksumValid ? "yes" : "no"))
        fields.append(.init("Checksum", hex(entry.checksum, digits: 2)))
        return fields
    }

    private static func sizeText(_ entry: FITEntry) -> String {
        // The header's `Size` counts entries, not bytes — the field everyone
        // reads wrong (§4). For the rows that use it, the field is in 16-byte
        // units; what a reader wants is the byte count.
        if entry.isHeader {
            return "\(entry.size) rows"
        }
        if entry.size == 0 { return "0" }
        return size(entry.sizeInBytes)
    }

    private static func reservedText(_ entry: FITEntry) -> String {
        // The reserved byte is a subtype on a CSE SecureBoot entry (§7.5).
        if entry.type == FIT.cseSecureBootType {
            return "\(entry.reserved)  \(FIT.cseSecureBootSubtypeName(entry.reserved))"
        }
        return hex(entry.reserved, digits: 2)
    }

    // MARK: - What the row points at

    private static func targetFields(of row: FITRow) -> [FITDetailField] {
        switch row.target {
        case .nothing:
            // The header and an empty slot point nowhere by design; the entry
            // fields above are the whole of what there is to say.
            return []
        case .indexIORegisters(let d):
            // The first eight bytes, read as a descriptor of Index/IO
            // registers rather than as the pointer they are shaped like (§7.3).
            return [
                .init("Index register", hex(d.indexRegister, digits: 4)),
                .init("Data register", hex(d.dataRegister, digits: 4)),
                .init("Access width", "\(d.accessWidth) byte" + (d.accessWidth == 1 ? "" : "s")),
                .init("Bit position", "\(d.bitPosition)"),
                .init("Index", hex(d.index, digits: 4))
            ]
        case .outsideTheImage:
            return [.init("Points at", "outside this image")]
        case .microcode(let header):
            return [
                .init("CPUID", FITPresenter.cpuid(header.processorSignature)),
                .init("Revision", hex(header.updateRevision)),
                .init("Date", header.date),
                .init("Data size", size(header.dataSize)),
                .init("Total size", size(header.totalSize)),
                .init("Platform IDs", hex(header.platformIDs)),
                // The image's own dword checksum, distinct from the row's
                // checksum byte above.
                .init("Image checksum", hex(header.checksum))
            ]
        case .emptyMicrocodeSlot(let offset):
            return [
                .init("Points at", "empty slot (FF FF FF FF)"),
                .init("Component", hex(offset, digits: 8))
            ]
        case .bytes(let offset, let description):
            var fields: [FITDetailField] = [
                .init("Points at", description ?? "unrecognised bytes"),
                .init("Component", hex(offset, digits: 8))
            ]
            if let length = row.effectiveSize {
                fields.append(.init("Length", size(length)))
            }
            return fields
        }
    }

    // MARK: - Text

    /// A size in bytes, said both ways: hex for the dump, decimal for the mind.
    private static func size<T: BinaryInteger>(_ bytes: T) -> String {
        let value = UInt64(truncatingIfNeeded: bytes)
        return "\(hex(value)) (\(value))"
    }

    private static func hex<T: BinaryInteger>(_ value: T, digits: Int = 0) -> String {
        let text = String(UInt64(truncatingIfNeeded: value), radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
