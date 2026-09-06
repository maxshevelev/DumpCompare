import Foundation
import ToolModuleKit
import UEFIFormat

/// Why a change to the table cannot be made.
///
/// Each of these is a rule from the specification, and each is worth saying in
/// a sentence rather than refusing silently: the user is at a bench with a
/// dump that has to boot afterwards.
public enum FITEditProblem: Equatable, Sendable, Error {
    /// The file this tool was pointed at is not a microcode image.
    case notMicrocode
    /// Its dword checksum does not come out at zero (§7.1).
    case microcodeChecksumIsWrong
    /// There is no microcode in the table to put the new one after, so there is
    /// no telling where this image keeps them (§9.2).
    case noMicrocodeToFollow
    /// No run of erased bytes long enough, in the area the existing microcode
    /// lives in.
    case noRoomForTheComponent(needed: UInt64)
    /// The table has no empty slot and the bytes after it are not free, so it
    /// cannot grow (§9.1).
    case theTableCannotGrow
    /// The header is not an entry to be removed (§10).
    case cannotRemoveTheHeader
    /// A table needs at least one microcode entry (§8.7).
    case cannotRemoveTheLastMicrocode
    case noSuchEntry
    /// Nothing to add to.
    case noTable

    public var message: String {
        switch self {
        case .notMicrocode:
            return "That file does not start with an Intel microcode header."
        case .microcodeChecksumIsWrong:
            return "That microcode's checksum does not add up — its dwords should sum to zero."
        case .noMicrocodeToFollow:
            return "There is no microcode in this table to put a new one after."
        case .noRoomForTheComponent(let needed):
            return "No erased run of 0x" + String(needed, radix: 16, uppercase: true)
                + " bytes after the last microcode."
        case .theTableCannotGrow:
            return "The table has no empty slot, and the bytes after it are not free."
        case .cannotRemoveTheHeader:
            return "The header is not an entry."
        case .cannotRemoveTheLastMicrocode:
            return "A FIT needs at least one microcode entry."
        case .noSuchEntry:
            return "That entry is no longer in the table."
        case .noTable:
            return "There is no FIT table in this file to change."
        }
    }
}

/// Where a new component would go.
public struct FITPlacement: Equatable, Sendable {
    public var range: Range<UInt64>
    /// The address it will be reachable at once written.
    public var address: UInt64
    /// Whether the row goes into an empty slot (§9.4) or the table has to grow
    /// by one. The safe way in is the slot: the table's length and position do
    /// not change, and neither does the pointer that leads to it.
    public var usesEmptySlot: Bool
}

/// The two changes this tool makes to a table: adding a microcode entry (§9.2)
/// and taking one out (§10).
///
/// Both come back as a `ToolTransaction` rather than as writes performed here:
/// a whole edit — the component, the rows shifted around it, the header's count
/// and its checksum — has to land as one undoable step or not at all. Neither
/// changes the file's size, which §9.2 step 8 requires: a flash dump is the
/// size of the chip it came off.
public enum FITEditor {
    /// A microcode image the user picked, checked before anything is written.
    public static func microcode(
        in bytes: [UInt8]
    ) -> Result<MicrocodeHeader, FITEditProblem> {
        let reader = ImageReader(bytes)
        guard let header = MicrocodeHeader.read(at: 0, in: reader),
              header.range.upperBound <= reader.count
        else { return .failure(.notMicrocode) }
        guard Checksums.sum32(of: header.range, in: reader) == 0 else {
            return .failure(.microcodeChecksumIsWrong)
        }
        return .success(header)
    }

    /// Where a component of `size` bytes can go (§9.2 step 1).
    ///
    /// Microcode lives in one run in every image worth the name, so the search
    /// starts right after the last one the table points at and stays inside
    /// whatever holds it — padding, free space, a microcode region. Staying
    /// inside is what keeps the component from crossing into another element or
    /// out of its flash region.
    ///
    /// What this cannot check is Boot Guard: the protected ranges are in
    /// structures `UEFIFormat` does not read yet (`Design/TODO.md`), and a
    /// component written inside one stops the platform booting. The panel says
    /// so rather than pretending otherwise.
    public static func placement(
        forSize size: UInt64,
        table: FITTable,
        image: UEFIImage?,
        reader: ImageReader,
        addressDiff: UInt64
    ) -> Result<FITPlacement, FITEditProblem> {
        guard size > 0 else { return .failure(.notMicrocode) }
        let components = table.rows.compactMap { row -> Range<UInt64>? in
            guard case .microcode(let header) = row.target else { return nil }
            return header.range
        }
        guard let last = components.max(by: { $0.upperBound < $1.upperBound }) else {
            return .failure(.noMicrocodeToFollow)
        }
        guard let start = alignUp(last.upperBound, to: 16) else {
            return .failure(.noRoomForTheComponent(needed: size))
        }

        // The element the existing microcode sits in bounds the search: a
        // component that ran past it would land in another structure, or in
        // another flash region.
        let area = spareArea(around: last.lowerBound, image: image, reader: reader)
        var candidate = start
        while candidate + size <= area.upperBound {
            if reader.isFilled(candidate..<(candidate + size), with: 0xFF) {
                return .success(FITPlacement(
                    range: candidate..<(candidate + size),
                    address: candidate + addressDiff,
                    usesEmptySlot: table.rows.contains { $0.entry.isEmptySlot }
                ))
            }
            guard let used = reader.firstOffset(
                in: candidate..<min(candidate + size, area.upperBound), notEqualTo: 0xFF
            ), let next = alignUp(used + 1, to: 16) else { break }
            candidate = next
        }
        return .failure(.noRoomForTheComponent(needed: size))
    }

    /// What bounds the search: the node the last microcode lives in, or the
    /// rest of the file when there is no tree to say.
    private static func spareArea(
        around offset: UInt64,
        image: UEFIImage?,
        reader: ImageReader
    ) -> Range<UInt64> {
        guard let image else { return offset..<reader.count }
        // The innermost node that is *space* rather than a structure. A
        // microcode component's own node is a structure, so what bounds the run
        // is whatever holds it — and where nothing does, which is what a
        // microcode found by the raw scan of a plain image looks like, the rest
        // of the file does.
        let chain = image.nodes(containing: offset)
        for node in chain.reversed() where node.kind != .microcode {
            return node.range
        }
        return offset..<reader.count
    }

    /// Adds a microcode entry: the component, and the table rebuilt around a
    /// new row (§9.2 steps 2 to 7).
    public static func addMicrocode(
        _ component: [UInt8],
        at placement: FITPlacement,
        to table: FITTable,
        in reader: ImageReader
    ) -> Result<ToolTransaction, FITEditProblem> {
        guard var rows = rowBytes(of: table, in: reader) else { return .failure(.noSuchEntry) }
        let row = entryBytes(address: placement.address)

        // Rows do not decrease in type (§3), so a microcode row goes after the
        // last one there is.
        let insertion = (rows.lastIndex { type(of: $0) == FIT.microcodeType } ?? 0) + 1
        if let slot = rows.indices.first(where: {
            $0 >= insertion && type(of: rows[$0]) == FIT.emptyType
        }) {
            // The safe way in (§9.4): the slot is eaten and everything between
            // it and the new row shifts down. The table's length, its position
            // and the pointer to it all stay as they were.
            rows.remove(at: slot)
            rows.insert(row, at: insertion)
        } else {
            let end = table.range.upperBound
            guard end + FITEntry.size <= reader.count,
                  reader.isFilled(end..<(end + FITEntry.size), with: 0xFF)
            else { return .failure(.theTableCannotGrow) }
            rows.insert(row, at: insertion)
        }

        return .success(ToolTransaction(
            name: "Add Microcode",
            writes: [
                ToolTransaction.Write(offset: placement.range.lowerBound, bytes: component),
                ToolTransaction.Write(
                    offset: table.range.lowerBound,
                    bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
                )
            ]
        ))
    }

    /// Takes an entry out (§10): the rows below it move up, and the sixteen
    /// bytes that frees at the end become an empty slot.
    ///
    /// A slot rather than a shorter table, of the two ways §10 offers: the
    /// table keeps its length and its place, the pointer at `0xFFFFFFC0` stays
    /// right, and the room is there for the next addition — which is what this
    /// tool is for.
    ///
    /// The component itself is left where it is. Erasing it is the riskier
    /// half of §10 step 5: it may be covered by a Boot Guard range or referred
    /// to by something else in the image.
    public static func removeEntry(
        _ index: Int,
        from table: FITTable,
        in reader: ImageReader
    ) -> Result<ToolTransaction, FITEditProblem> {
        guard index > 0 else { return .failure(.cannotRemoveTheHeader) }
        guard var rows = rowBytes(of: table, in: reader), index < rows.count else {
            return .failure(.noSuchEntry)
        }
        if type(of: rows[index]) == FIT.microcodeType,
           rows.filter({ type(of: $0) == FIT.microcodeType }).count == 1 {
            return .failure(.cannotRemoveTheLastMicrocode)
        }

        rows.remove(at: index)
        rows.append(emptySlotBytes())
        return .success(ToolTransaction(
            name: "Remove FIT Entry",
            writes: [ToolTransaction.Write(
                offset: table.range.lowerBound,
                bytes: assemble(rows, checksumIsChecked: table.checksumIsChecked)
            )]
        ))
    }

    // MARK: - Rows as bytes

    /// The table as sixteen-byte rows, read back rather than rebuilt from what
    /// was parsed: a row carries fields this tool does not model, and rewriting
    /// one from a struct would quietly drop them.
    private static func rowBytes(of table: FITTable, in reader: ImageReader) -> [[UInt8]]? {
        guard let bytes = reader.bytes(table.range), bytes.count % Int(FITEntry.size) == 0
        else { return nil }
        return stride(from: 0, to: bytes.count, by: Int(FITEntry.size)).map {
            Array(bytes[$0..<($0 + Int(FITEntry.size))])
        }
    }

    private static func type(of row: [UInt8]) -> UInt8 { row[0x0E] & 0x7F }

    /// The header's count and the checksum, which are the two fields that
    /// depend on every other byte of the table (§4, §5).
    private static func assemble(_ rows: [[UInt8]], checksumIsChecked: Bool) -> [UInt8] {
        var rows = rows
        let count = UInt32(rows.count)
        for index in 0..<3 {
            rows[0][0x08 + index] = UInt8(truncatingIfNeeded: count >> (8 * index))
        }
        rows[0][0x0F] = 0
        var bytes = rows.flatMap { $0 }
        if checksumIsChecked {
            bytes[0x0F] = 0 &- Checksums.sum8(bytes)
        }
        return bytes
    }

    /// §9.2 step 5, field for field.
    private static func entryBytes(address: UInt64) -> [UInt8] {
        var row = (0..<8).map { UInt8(truncatingIfNeeded: address >> (8 * $0)) }
        row += [0, 0, 0]                 // Size — unused for microcode (§7.1)
        row += [0]                       // Reserved
        row += [0x00, 0x01]              // Version 0x0100
        row += [FIT.microcodeType]       // Type, with ChecksumValid clear
        row += [0]                       // Checksum
        return row
    }

    /// §9.4: an address of zero, no size, version 0x0100, type 0x7F.
    private static func emptySlotBytes() -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + [0x00, 0x01, FIT.emptyType, 0]
    }
}
