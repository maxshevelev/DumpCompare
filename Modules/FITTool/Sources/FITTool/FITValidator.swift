import Foundation
import UEFIImage

/// The invariants of §8, each one checked and each one named.
///
/// They are worth having as a list rather than as scattered `if`s, because the
/// list *is* the deliverable: a bench opens this panel to be told what a hand
/// edit broke, and "types out of order at entry 5" is the whole answer.
public enum FITValidator {
    public static func problems(
        in table: FITTable,
        reader: ImageReader,
        addressDiff: UInt64
    ) -> [FITProblem] {
        var problems: [FITProblem] = []

        // §8.2 — the first entry is the header.
        if let first = table.rows.first?.entry, !first.isHeader {
            problems.append(FITProblem(
                .firstEntryIsNotTheHeader(type: first.type), entry: 0, at: first.offset + 0x0E
            ))
        }

        // §8.6 — the checksum, but only when the header says it counts.
        if table.checksumIsChecked, !table.checksumIsCorrect {
            problems.append(FITProblem(
                .checksumMismatch(stored: table.storedChecksum, computed: table.computedChecksum),
                entry: 0,
                at: table.range.lowerBound + 0x0F
            ))
        }

        var previousType: UInt8?
        for row in table.rows.dropFirst() {
            let entry = row.entry

            // §8.4 — one header only.
            if entry.isHeader {
                problems.append(FITProblem(
                    .secondHeader, entry: entry.index, at: entry.offset + 0x0E
                ))
            }
            // §8.5 — types do not decrease.
            if let previous = previousType, entry.type < previous {
                problems.append(FITProblem(
                    .typesOutOfOrder(previous: previous, type: entry.type),
                    entry: entry.index,
                    at: entry.offset + 0x0E
                ))
            }
            previousType = entry.type

            // §3 — reserved is zero, except on a CSE SecureBoot entry, where it
            // is the subtype (§7.5).
            if entry.reserved != 0, entry.type != FIT.cseSecureBootType {
                problems.append(FITProblem(
                    .reservedIsNotZero(value: entry.reserved),
                    entry: entry.index,
                    at: entry.offset + 0x0B
                ))
            }

            problems += addressProblems(of: row)
        }

        // §8.7 — at least one microcode entry.
        if !table.rows.contains(where: { $0.entry.type == FIT.microcodeType }) {
            problems.append(FITProblem(.noMicrocodeEntry, at: table.range.lowerBound))
        }
        return problems
    }

    /// §8.8, §8.9 and §8.10 — the three that are about where a row points, and
    /// the ones a mistyped address trips.
    private static func addressProblems(of row: FITRow) -> [FITProblem] {
        let entry = row.entry
        switch row.target {
        case .nothing, .indexIORegisters:
            return []
        case .outsideTheImage:
            return [FITProblem(
                .addressOutsideTheImage(address: entry.address),
                entry: entry.index,
                at: entry.offset
            )]
        case .microcode, .emptyMicrocodeSlot, .bytes:
            var problems: [FITProblem] = []
            if entry.address % 16 != 0 {
                problems.append(FITProblem(
                    .addressNotAligned(address: entry.address),
                    entry: entry.index,
                    at: entry.offset
                ))
            }
            if entry.type == FIT.microcodeType, case .bytes = row.target {
                problems.append(FITProblem(
                    .notMicrocodeAtTheAddress(address: entry.address),
                    entry: entry.index,
                    at: entry.offset
                ))
            }
            return problems
        }
    }
}
