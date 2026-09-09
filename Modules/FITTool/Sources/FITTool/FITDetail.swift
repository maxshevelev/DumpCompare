import Foundation
import UEFIImage

/// One label/value row in the detail list.
public struct FITDetailField: Equatable, Sendable {
    public var label: String
    public var value: String
    /// A value that reads as a problem — a checksum that does not check out.
    /// The controller colours just this row's value with it; everything else
    /// stays as it is, the same way the UEFI detail marks its own.
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
    /// `checksumMismatch` is the validator's word on the table's own checksum
    /// (§8.6) — the one thing about the header row that cannot be read off the
    /// row, and the value the header's Checksum field is coloured by.
    public static func build(for row: FITRow, checksumMismatch: Bool = false) -> FITRowDetail {
        let entry = row.entry
        var fields = entryFields(of: entry, checksumMismatch: checksumMismatch)
        fields += targetFields(of: row)
        return FITRowDetail(
            // The number the panel shows for the row, counting from one the way
            // the table and the zones do — not the header's zero, which is its
            // place, not its number.
            title: "#\(entry.index + 1) \(FIT.typeName(entry.type))",
            fields: fields
        )
    }

    // MARK: - The sixteen bytes of the row itself

    private static func entryFields(
        of entry: FITEntry, checksumMismatch: Bool
    ) -> [FITDetailField] {
        // The type leads: it is what the row is, and the title already says it,
        // so the fields open with it rather than with where it sits.
        var fields: [FITDetailField] = [
            .init("Type", "\(FIT.typeName(entry.type)) · \(hex(entry.type, digits: 2))")
        ]
        fields.append(.init("Offset", hex(entry.offset, digits: 8)))
        fields.append(.init("Address", entry.isHeader ? "_FIT_" : hex(entry.address, digits: 8)))
        fields.append(.init("Size", sizeText(entry)))
        fields.append(.init("Revision", entry.versionText))
        // The checksum byte is the header's (§5), so it is shown on the header
        // row and on no other — a row that is not the header does not carry it.
        if entry.isHeader {
            // Valid means the byte counts *and* checks out — the same thing
            // "Valid" means everywhere else a checksum is read, so the word
            // can be trusted. A header that says its checksum does not count
            // (the C_V bit, §5) says so in as many words: the byte is not
            // wrong, it is not looked at, and nothing about it is a problem.
            fields.append(entry.checksumValid
                ? .init("Checksum",
                        Checksums.text(entry.checksum, valid: !checksumMismatch),
                        isProblem: checksumMismatch)
                : .init("Checksum", "\(hex(entry.checksum, digits: 2)) (Not checked)"))
        }
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
                // The microcode's own update revision — "Update revision" so it
                // does not read as the same thing as the entry's Revision above.
                .init("Update revision", hex(header.updateRevision)),
                .init("Date", header.date),
                .init("Data size", size(header.dataSize)),
                .init("Total size", size(header.totalSize)),
                .init("Platform IDs", hex(header.platformIDs)),
                // The image's own dword checksum, distinct from the header's
                // checksum byte. Shown with whether the image sums to zero, the
                // shared spelling, so it reads the same wherever a checksum
                // carries a validity.
                .init("Image checksum",
                      Checksums.text(header.checksum, valid: header.checksumIsCorrect, digits: 4),
                      isProblem: !header.checksumIsCorrect)
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
