import Foundation
import ToolModuleKit
import UEFIFormat

/// One row as the panel shows it.
public struct FITDisplayRow: Equatable, Sendable {
    /// Its place in the table; 0 is the header.
    public var index: Int
    public var typeText: String
    public var addressText: String
    /// Empty when the type does not use `Size` — deliberately not `0x0`, which
    /// is indistinguishable from a size that was never written (§11).
    public var sizeText: String
    public var versionText: String
    /// What is actually there, read rather than assumed.
    public var targetText: String
    /// Something is wrong with this row, and the panel says so by colour as
    /// well as in the list below.
    public var hasProblem: Bool
    /// The zone for the row itself — sixteen bytes of the table.
    public var zoneID: String
    /// Where the row points, when it points into the image.
    public var targetRange: Range<UInt64>?
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

    /// Nothing read yet, or nothing to show.
    public static let empty = FITDisplay(
        summary: "", rows: [], problems: [], checksumFix: nil, zones: .empty
    )

    /// The same display with another row selected. Selecting a row changes
    /// what is drawn strongly in the dump and nothing else, so it is a change
    /// to the focus rather than a reason to read the file again.
    public func focusing(_ index: Int?) -> FITDisplay {
        var copy = self
        copy.zones.focus = index.map(FITPresenter.rowZoneID)
        return copy
    }
}

public enum FITPresenter {
    public static let tableZoneID = "fit.table"
    public static let pointerZoneID = "fit.pointer"

    public static func rowZoneID(_ index: Int) -> String { "fit.row.\(index)" }
    public static func targetZoneID(_ index: Int) -> String { "fit.target.\(index)" }

    /// What to show for a report. `focus` is the row the user has selected.
    public static func display(_ report: FITReport, focus: Int? = nil) -> FITDisplay {
        guard let table = report.table else {
            return FITDisplay(
                summary: summary(of: report),
                rows: [],
                problems: report.problems,
                checksumFix: nil,
                zones: ZoneMap.empty
            )
        }
        let problemRows = Set(report.problems.compactMap(\.entryIndex))
        let rows = table.rows.map { row in
            FITDisplayRow(
                index: row.entry.index,
                typeText: typeText(of: row.entry),
                addressText: row.entry.isHeader ? "_FIT_" : hex(row.entry.address, digits: 8),
                sizeText: row.effectiveSize.map { hex($0) } ?? "",
                versionText: row.entry.versionText,
                targetText: targetText(of: row),
                hasProblem: problemRows.contains(row.entry.index),
                zoneID: rowZoneID(row.entry.index),
                targetRange: targetRange(of: row)
            )
        }
        return FITDisplay(
            summary: summary(of: report),
            rows: rows,
            problems: report.problems,
            checksumFix: checksumFix(for: table),
            zones: zones(of: table, rows: rows, focus: focus)
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
        var parts = [
            "FIT at \(hex(table.range.lowerBound))",
            "\(table.entries.count) " + (table.entries.count == 1 ? "entry" : "entries")
        ]
        if !table.checksumIsChecked {
            parts.append("checksum unused")
        } else if table.checksumIsCorrect {
            parts.append("checksum \(hex(UInt64(table.storedChecksum), digits: 2))")
        } else {
            parts.append("checksum \(hex(UInt64(table.storedChecksum), digits: 2)),"
                + " should be \(hex(UInt64(table.computedChecksum), digits: 2))")
        }
        return parts.joined(separator: " · ")
    }

    private static func typeText(of entry: FITEntry) -> String {
        let name = FIT.typeName(entry.type)
        guard entry.type == FIT.cseSecureBootType else { return name }
        return "\(name): \(FIT.cseSecureBootSubtypeName(entry.reserved))"
    }

    private static func targetText(of row: FITRow) -> String {
        switch row.target {
        case .nothing:
            return ""
        case .indexIORegisters:
            return "Index/IO registers, not an address"
        case .outsideTheImage:
            return "outside this image"
        case .microcode(let header):
            return "Microcode \(hex(UInt64(header.processorSignature), digits: 8)),"
                + " revision \(hex(UInt64(header.updateRevision), digits: 2)), \(header.date)"
        case .emptyMicrocodeSlot:
            return "empty slot"
        case .bytes(_, let description):
            return description ?? "unrecognised bytes"
        }
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
                name: "#\(row.index) \(row.typeText)",
                range: start..<(start + FITEntry.size)
            ))
            if let target = row.targetRange {
                zones.append(Zone(
                    id: targetZoneID(row.index),
                    name: row.targetText.isEmpty ? "#\(row.index)" : row.targetText,
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
