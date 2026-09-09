import Foundation
import ToolModuleKit
import UEFIImage

/// One row as the panel shows it.
public struct FITDisplayRow: Equatable, Sendable {
    /// Its place in the table; 0 is the header.
    public var index: Int
    /// The number the panel shows for the row. Counting starts at one, the way
    /// a reader counts the rows of a table, rather than at the header's zero —
    /// which is the row's place, not its number.
    public var displayNumber: Int { index + 1 }
    public var typeText: String
    public var addressText: String
    /// The size worth showing, in its own column: the component's for the rows
    /// that point at one, the header's entry count for the header, and `0` for
    /// a row whose size field is empty.
    public var sizeText: String
    public var versionText: String
    /// What is actually there, read rather than assumed: for microcode the
    /// CPUID, the revision, the date, and where and how long it is.
    public var targetText: String
    /// The CPUID of the microcode this row leads to, as five hex digits with no
    /// leading zero — what a bench writes down and looks up. Nil for a row that
    /// does not lead to microcode.
    public var cpuidText: String?
    /// Something is wrong with this row, and the panel says so by colour as
    /// well as in the list below.
    public var hasProblem: Bool
    /// How this row's microcode stands against the catalogue, when the row
    /// leads to one and there is a basis for a verdict: whether a newer
    /// revision for the same processor and platform is out there. `.notRated`
    /// before the catalogue arrives, for a row that is not a microcode, and
    /// wherever nothing the collection holds matches. The Type column wears it
    /// as an icon ahead of the warning.
    public var latestState: MicrocodeLatest
    /// The zone for the row itself — sixteen bytes of the table.
    public var zoneID: String
    /// Those sixteen bytes.
    public var rowRange: Range<UInt64>
    /// Where the row points, when it points into the image.
    public var targetRange: Range<UInt64>?
    /// Whether this row is a microcode that may go. Only a microcode is
    /// offered for removal — the extent of anything else a row can point at is
    /// not something this tool knows — and a table keeps one microcode (§8.7),
    /// so the last one a table has cannot be removed.
    public var canRemove: Bool
    /// Whether the microcode this row names may be swapped for another. Every
    /// microcode row may be replaced — the slot stays, so the one-microcode
    /// rule (§8.7) is not touched — and the replacement need not be the same
    /// CPUID: the row, not the processor, is what is being changed.
    public var canReplace: Bool
    /// Whether this row offers the checksum fix. The byte is the header's
    /// (§5), so the fix lives on the header row — the one the mismatch turns
    /// red — and on no other.
    public var checksumFixAvailable: Bool
    /// The row as the table read it — entry and what it points at — kept so
    /// the detail can be rebuilt for whatever row comes into focus.
    public var model: FITRow

    /// Where "go to the offset" leads: what the row points at, or — for the
    /// header and for an empty slot, which point nowhere — the row itself.
    /// Every row has an offset, so every row has somewhere to go.
    public var offsetToGoTo: UInt64 { (targetRange ?? rowRange).lowerBound }

    /// The zone that "go to the offset" brings to the front.
    public var zoneToFocus: String {
        targetRange == nil ? zoneID : FITPresenter.targetZoneID(index)
    }

    /// What the right-button menu offers here. Every row leads with its offset
    /// — going where the row points is the point of the row — and a row that
    /// leads to microcode offers the CPUID, its replacement, and — when it may
    /// go — its removal. The checksum fix is offered on the header row, where
    /// the byte lives, when it is needed.
    public var commands: [FITRowCommand] {
        var commands: [FITRowCommand] = [.goToOffset(offsetToGoTo)]
        if let cpuidText { commands.append(.copyCPUID(cpuidText)) }
        if canReplace { commands.append(.replaceMicrocode(index)) }
        if canRemove { commands.append(.removeMicrocode(index)) }
        if checksumFixAvailable { commands.append(.fixChecksum) }
        return commands
    }
}

/// What the right-button menu offers for a row.
///
/// A value rather than a menu, so what is on offer is decided in the pure
/// target and tested by `swift test`: the panel builds items from this and
/// nothing more. An item that does not apply to the row is *absent* rather than
/// present and greyed — a greyed "Copy CPUID" on the header row explains
/// nothing.
public enum FITRowCommand: Equatable, Sendable {
    /// The number a bench writes down and looks up.
    case copyCPUID(String)
    /// Go to what the row points at, and put it in focus.
    case goToOffset(UInt64)
    /// Swap the microcode this row names for another, whatever its CPUID. The
    /// row stays; only the component it points at changes.
    case replaceMicrocode(Int)
    /// Take the microcode out of the table (§10). The component it named stays
    /// in the image: erasing it is the riskier half of the edit.
    case removeMicrocode(Int)
    /// Write the checksum this table should have (§5, §11). The byte is the
    /// header's, so the offer sits on the header row — the one the mismatch
    /// turns red — and not on the rows it is not about.
    case fixChecksum

    public var title: String {
        switch self {
        case .copyCPUID: return "Copy CPUID"
        case .goToOffset: return "Go to Offset"
        case .replaceMicrocode: return "Replace Microcode"
        case .removeMicrocode: return "Remove Microcode"
        case .fixChecksum: return "Fix Checksum"
        }
    }
}

/// Everything the panel draws, in one value.
///
/// It is built in the pure target and tested by `swift test`, so the view
/// controller has no decisions left in it: it lays out what this says.
public struct FITDisplay: Equatable, Sendable {
    public var summary: String
    public var rows: [FITDisplayRow]
    public var problems: [FITProblem]
    /// The writes that would put the table's checksum right, or nil when there
    /// is nothing to put right (§5, §11).
    public var checksumFix: ToolTransaction?
    public var zones: ZoneMap
    /// What the row in focus is, field by field — the entry's own sixteen
    /// bytes and what its address leads to. Empty when no row is in focus.
    public var detail: FITRowDetail

    /// Nothing read yet, or nothing to show.
    public static let empty = FITDisplay(
        summary: "", rows: [], problems: [], checksumFix: nil, zones: .empty,
        detail: .empty
    )

    /// The same display with another row selected. Selecting a row changes
    /// what is drawn strongly in the dump and what the detail says, so it is a
    /// change to the focus rather than a reason to read the file again.
    public func focusing(_ index: Int?) -> FITDisplay {
        focusing(zoneID: index.map(FITPresenter.rowZoneID))
    }

    /// The same display with what "go to the offset" leads to in focus: the
    /// component a row points at, or the row itself where it points nowhere.
    public func focusingTarget(of index: Int) -> FITDisplay {
        guard let row = rows.first(where: { $0.index == index }) else { return self }
        return focusing(zoneID: row.zoneToFocus)
    }

    public func focusing(zoneID: String?) -> FITDisplay {
        var copy = self
        copy.zones.focus = zoneID
        // The detail follows the selection: the row the outline is on, whether
        // the outline sits on the row itself or on what it points at. The table
        // and the pointer stand for no row, so they leave the detail empty.
        copy.detail = zoneID
            .flatMap(FITPresenter.rowIndex(ofZone:))
            .flatMap { index in rows.first { $0.index == index } }
            .map {
                FITDetail.build(for: $0.model,
                                checksumShouldBe: FITPresenter.checksumShouldBe(in: problems))
            }
            ?? .empty
        return copy
    }
}

extension FITDisplay {
    /// The same display with every microcode row's "latest" verdict decided
    /// against the catalogue — the newest revision it lists for that row's
    /// processor and platform, or nothing where there is no basis for one.
    ///
    /// Applied when the catalogue arrives, and again whenever the table is
    /// re-read with the catalogue already in hand. It changes the marks, never
    /// the map: the zones, the focus and the detail ride on untouched, so a
    /// catalogue landing late does not move the outline the user is looking at.
    public func ratingLatest(against catalogue: [MicrocodeCatalogueEntry]) -> FITDisplay {
        guard !catalogue.isEmpty else { return self }
        var copy = self
        for index in copy.rows.indices {
            guard case .microcode(let header) = copy.rows[index].model.target else { continue }
            copy.rows[index].latestState = MicrocodeCatalogue.latest(of: header, in: catalogue)
        }
        return copy
    }
}

public enum FITPresenter {
    public static let tableZoneID = "fit.table"
    public static let pointerZoneID = "fit.pointer"

    public static func rowZoneID(_ index: Int) -> String { "fit.row.\(index)" }
    public static func targetZoneID(_ index: Int) -> String { "fit.target.\(index)" }

    /// Which row a zone id belongs to, for the trip back: the user picks a zone
    /// in the dump and the panel has to select the row it came from. Nil for
    /// the table and the pointer, which stand for no row in particular.
    public static func rowIndex(ofZone id: String) -> Int? {
        for prefix in ["fit.row.", "fit.target."] where id.hasPrefix(prefix) {
            return Int(id.dropFirst(prefix.count))
        }
        return nil
    }

    /// The byte the table's checksum should hold, as the validator computed it
    /// (§8.6) — what the header row's Checksum field quotes and is coloured by
    /// when it reads wrong. Nil when the checksum checks out or is not checked.
    /// It is not something the row itself carries: the byte the row holds is
    /// checked against the whole table.
    static func checksumShouldBe(in problems: [FITProblem]) -> UInt8? {
        for problem in problems {
            if case .checksumMismatch(_, let computed) = problem.kind { return computed }
        }
        return nil
    }

    /// What to show for a report. `focus` is the row the user has selected.
    public static func display(_ report: FITReport, focus: Int? = nil) -> FITDisplay {
        guard let table = report.table else {
            return FITDisplay(
                summary: summary(of: report),
                rows: [],
                problems: report.problems,
                checksumFix: nil,
                zones: ZoneMap.empty,
                detail: .empty
            )
        }
        let problemRows = Set(report.problems.compactMap(\.entryIndex))
        // No catalogue yet: the "latest" verdict for the microcode rows starts
        // `.notRated`, and the session's `ratingLatest(against:)` fills the
        // verdicts in once the catalogue is in hand.
        let latestState: MicrocodeLatest = .notRated
        // A table needs one microcode entry (§8.7), so the last one cannot go.
        let microcodeCount = table.rows.filter { $0.entry.type == FIT.microcodeType }.count
        // The checksum byte is the header's (§5), so the fix is offered on the
        // header row — the one the mismatch turns red — and on no other.
        let checksumFix = checksumFix(for: table)
        let rows = table.rows.map { row in
            FITDisplayRow(
                index: row.entry.index,
                typeText: typeText(of: row.entry),
                addressText: row.entry.isHeader ? "_FIT_" : hex(row.entry.address, digits: 8),
                sizeText: sizeText(of: row),
                versionText: row.entry.versionText,
                targetText: targetText(of: row),
                cpuidText: cpuidText(of: row),
                hasProblem: problemRows.contains(row.entry.index),
                latestState: latestState,
                zoneID: rowZoneID(row.entry.index),
                rowRange: row.entry.offset..<(row.entry.offset + FITEntry.size),
                targetRange: targetRange(of: row),
                canRemove: row.entry.type == FIT.microcodeType && microcodeCount > 1,
                canReplace: row.entry.type == FIT.microcodeType,
                checksumFixAvailable: checksumFix != nil && row.entry.index == 0,
                model: row
            )
        }
        // The detail is the row the user has selected, or nothing before a
        // selection — built here so a fresh parse shows the same detail the
        // selection would.
        let detail = focus
            .flatMap { index in rows.first { $0.index == index } }
            .map {
                FITDetail.build(for: $0.model,
                                checksumShouldBe: checksumShouldBe(in: report.problems))
            }
            ?? .empty
        return FITDisplay(
            summary: summary(of: report),
            rows: rows,
            problems: report.problems,
            checksumFix: checksumFix,
            zones: zones(of: table, rows: rows, focus: focus),
            detail: detail
        )
    }

    /// The one edit this tool-module makes: the header's checksum byte, which
    /// an editor that changed the table and did not recompute leaves behind
    /// (§11's second defect). One byte, one named undo step.
    public static func checksumFix(for table: FITTable) -> ToolTransaction? {
        guard table.checksumIsChecked, !table.checksumIsCorrect else { return nil }
        return ToolTransaction(
            name: "Fix FIT Checksum",
            writes: [ToolTransaction.Write(
                offset: table.range.lowerBound + 0x0F,
                bytes: [table.computedChecksum]
            )]
        )
    }

    // MARK: - Text

    private static func summary(of report: FITReport) -> String {
        guard let table = report.table else {
            return report.candidates.isEmpty
                ? "No FIT table in this file."
                : "No FIT table where the pointer leads. A signature sits at "
                    + report.candidates.map { hex($0) }.joined(separator: ", ") + "."
        }
        // The count includes the header row: the panel shows the header as a
        // row of the table, so the number the summary says is the number of
        // rows a reader counts, header included.
        let count = table.rows.count
        var parts = [
            "FIT at \(hex(table.range.lowerBound))",
            "\(count) " + (count == 1 ? "entry" : "entries")
        ]
        if report.addressDiffIsAssumed {
            // Said every time, because it is true every time for a region cut
            // out of a dump — and there every address in the table is wrong by
            // whatever was cut off in front of it.
            parts.append("addresses assumed")
        }
        if !table.checksumIsChecked {
            parts.append("checksum unused")
        } else if table.checksumIsCorrect {
            parts.append("checksum \(hex(UInt64(table.storedChecksum), digits: 2))")
            // A wrong checksum is not restated here: it is a problem, and the
            // list below already says so in red, where it is meant to be read.
        }
        return parts.joined(separator: " · ")
    }

    private static func typeText(of entry: FITEntry) -> String {
        let name = FIT.typeName(entry.type)
        guard entry.type == FIT.cseSecureBootType else { return name }
        return "\(name): \(FIT.cseSecureBootSubtypeName(entry.reserved))"
    }

    /// The size worth showing, in its own column. The header's field counts
    /// entries rather than bytes (§4), so it says so; a microcode's field is
    /// required to be zero, so the truth is the component's (§7.1); the rest
    /// use the field in 16-byte units, and an empty field is a zero, not a
    /// mystery.
    private static func sizeText(of row: FITRow) -> String {
        if row.entry.isHeader {
            return "\(row.entry.size) rows"
        }
        guard let size = row.effectiveSize else { return "0" }
        return hex(size)
    }

    /// The CPUID as a bench writes it: five hex digits, no leading zero, no
    /// `0x` — `806EA`, not `0x000806EA`.
    public static func cpuid(_ signature: UInt32) -> String {
        String(signature, radix: 16, uppercase: true)
    }

    private static func cpuidText(of row: FITRow) -> String? {
        guard case .microcode(let header) = row.target else { return nil }
        return cpuid(header.processorSignature)
    }

    /// Everything known about where the row leads, in one line, separated the
    /// way the summary is. A microcode row leads with its CPUID rather than
    /// with the word "microcode": the type column has already said that, and
    /// the CPUID is the thing being looked for.
    private static func targetText(of row: FITRow) -> String {
        var parts: [String] = []
        switch row.target {
        case .nothing:
            // The header's `Size` is a count of entries, not a size — the field
            // everyone reads wrong (§4) — so it is spelled out as both.
            guard row.entry.isHeader else { return "" }
            // "Rows" and not "entries": the field counts the header along with
            // them, where the summary above counts what there is to look at.
            return "\(row.entry.size) "
                + (row.entry.size == 1 ? "row" : "rows")
                + " · \(hex(row.entry.sizeInBytes))"
        case .indexIORegisters:
            return "Index/IO registers, not an address"
        case .outsideTheImage:
            return "outside this image"
        case .microcode(let header):
            // The CPUID is what a bench hunts for, so it leads; the offset and
            // the size have their own columns, and the date closes the line.
            parts = [
                "CPUID \(cpuid(header.processorSignature))",
                "r.\(String(header.updateRevision, radix: 16, uppercase: true))"
            ]
            parts.append(header.date)
            return parts.joined(separator: " · ")
        case .emptyMicrocodeSlot:
            parts = ["empty slot"]
        case .bytes(_, let description):
            parts = [description ?? "unrecognised bytes"]
        }
        if let offset = row.target.offset {
            parts.append(hex(offset))
        }
        return parts.joined(separator: " · ")
    }

    private static func targetRange(of row: FITRow) -> Range<UInt64>? {
        switch row.target {
        case .microcode(let header):
            return header.range
        case .emptyMicrocodeSlot(let offset), .bytes(let offset, _):
            let size = row.effectiveSize ?? 16
            return offset..<(offset + size)
        case .nothing, .indexIORegisters, .outsideTheImage:
            return nil
        }
    }

    // MARK: - Zones

    /// What the dump draws: the table, the pointer that leads to it, each row,
    /// and what each row points at — the last being the useful one, since the
    /// components are scattered across the image and the table is not.
    private static func zones(
        of table: FITTable,
        rows: [FITDisplayRow],
        focus: Int?
    ) -> ZoneMap {
        var zones = [
            Zone(id: tableZoneID, name: "FIT table", range: table.range),
            Zone(
                id: pointerZoneID,
                name: "FIT pointer",
                range: table.pointerOffset..<(table.pointerOffset + 4)
            )
        ]
        for row in rows {
            let start = table.range.lowerBound + UInt64(row.index) * FITEntry.size
            zones.append(Zone(
                id: row.zoneID,
                name: "#\(row.displayNumber) \(row.typeText)",
                range: start..<(start + FITEntry.size)
            ))
            if let target = row.targetRange {
                // Named by CPUID where there is one: that is what a bench is
                // looking for when it goes hunting for a microcode in a dump.
                zones.append(Zone(
                    id: targetZoneID(row.index),
                    name: row.cpuidText.map { "CPUID \($0)" }
                        ?? (row.targetText.isEmpty ? "#\(row.displayNumber)" : row.targetText),
                    range: target
                ))
            }
        }
        return ZoneMap(zones: zones, focus: focus.map(rowZoneID))
    }

    private static func hex(_ value: UInt64, digits: Int = 0) -> String {
        let text = String(value, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
