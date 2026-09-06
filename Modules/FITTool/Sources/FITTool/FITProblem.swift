import Foundation

/// Something wrong with the table, or with the image around it.
///
/// Collected and shown, never thrown: a FIT worth opening a tool on is usually
/// one somebody has already edited by hand, and the defects are what the user
/// came to see. Each problem carries the offset to look at, so the panel can
/// send the dump there.
public struct FITProblem: Equatable, Sendable {
    public enum Severity: Sendable {
        /// The table breaks a rule the specification states as one (§8).
        case error
        /// Worth saying, but the table still works.
        case warning
    }

    public enum Kind: Equatable, Sendable {
        /// No Volume Top File, so the image was taken to be mapped against the
        /// top of the address space. True of a full flash dump; false of a
        /// region cut out of one, where every address here will be wrong by
        /// whatever was cut off.
        case addressesAssumed(addressDiff: UInt64)
        case imageHasNoPointer
        case pointerLeadsOutsideTheImage(address: UInt64)
        case noTableAtThePointer(address: UInt64)
        case tableHasNoEntries
        case tableRunsPastTheEnd(entries: UInt32)
        case firstEntryIsNotTheHeader(type: UInt8)
        case secondHeader
        /// Rows must not decrease in type: a FIT handler is allowed to stop
        /// looking at the first type past the one it wants (§3).
        case typesOutOfOrder(previous: UInt8, type: UInt8)
        case checksumMismatch(stored: UInt8, computed: UInt8)
        case noMicrocodeEntry
        case addressOutsideTheImage(address: UInt64)
        case addressNotAligned(address: UInt64)
        /// A microcode row pointing at something that is neither a microcode
        /// header nor an empty slot — the defect §11 is a post-mortem of, and
        /// the reason a tool must read what it wrote an address to.
        case notMicrocodeAtTheAddress(address: UInt64)
        case reservedIsNotZero(value: UInt8)
    }

    public var kind: Kind
    /// The row it is about, when it is about one.
    public var entryIndex: Int?
    /// Where to send the dump.
    public var offset: UInt64?

    public init(_ kind: Kind, entry: Int? = nil, at offset: UInt64? = nil) {
        self.kind = kind
        self.entryIndex = entry
        self.offset = offset
    }

    public var severity: Severity {
        switch kind {
        case .addressesAssumed, .reservedIsNotZero:
            return .warning
        default:
            return .error
        }
    }

    public var message: String {
        switch kind {
        case .addressesAssumed(let diff):
            return "No volume top file: assuming the image is mapped at "
                + hex(0x1_0000_0000 - diff <= 0 ? 0 : diff) + " and up"
        case .imageHasNoPointer:
            return "The image is too small to hold a FIT pointer"
        case .pointerLeadsOutsideTheImage(let address):
            return "The FIT pointer, \(hex(address)), is outside this image"
        case .noTableAtThePointer(let address):
            return "No FIT signature at \(hex(address)), where the pointer leads"
        case .tableHasNoEntries:
            return "The header says the table has no entries"
        case .tableRunsPastTheEnd(let entries):
            return "The header claims \(entries) entries, which runs past the end of the image"
        case .firstEntryIsNotTheHeader(let type):
            return "The first entry is type \(hex(UInt64(type))), not the header"
        case .secondHeader:
            return "A second header entry, where there may be only one"
        case .typesOutOfOrder(let previous, let type):
            return "Type \(hex(UInt64(type))) after type \(hex(UInt64(previous))): "
                + "entries must not decrease in type"
        case .checksumMismatch(let stored, let computed):
            return "The table checksum is \(hex(UInt64(stored))), and should be "
                + hex(UInt64(computed))
        case .noMicrocodeEntry:
            return "No microcode entry, and there must be at least one"
        case .addressOutsideTheImage(let address):
            return "\(hex(address)) is outside this image"
        case .addressNotAligned(let address):
            return "\(hex(address)) is not aligned to 16 bytes"
        case .notMicrocodeAtTheAddress(let address):
            return "No microcode header at \(hex(address)), and it is not an empty slot"
        case .reservedIsNotZero(let value):
            return "The reserved byte is \(hex(UInt64(value))), and should be zero"
        }
    }

    private func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}
