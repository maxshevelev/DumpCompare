import Foundation
import MEFirmware

/// The value a summary row carries: the fact the analysis answered, or the
/// placeholder that names a row upstream MEA prints but this engine does not
/// surface yet. The latter is shown grey ("Coming soon"), never hidden — so the
/// shape of the full default output is visible from the first version, and each
/// row lights up as the bridge reaches it.
public enum MEASummaryValue: Sendable, Equatable {
    /// A real, selectable value (formatted with `MEAText`).
    case value(String)
    /// The engine has nothing for this row yet.
    case comingSoon
}

/// One Field/Value row of the summary — the same shape as `MEAField`, with the
/// not-yet-surfaced value added.
public struct MEASummaryRow: Sendable, Equatable {
    public var label: String
    public var value: MEASummaryValue

    public init(_ label: String, _ value: MEASummaryValue) {
        self.label = label
        self.value = value
    }
}

/// A titled group of summary rows. The primary firmware table carries no title
/// (as in MEA's console); a messages list is its own block, present only when
/// the analysis raised something to say.
public struct MEASummaryBlock: Sendable, Equatable {
    public var title: String?
    public var rows: [MEASummaryRow]

    public init(title: String?, rows: [MEASummaryRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Turns a `FirmwareAnalysis` into the «Summary» tab's rows: the primary
/// firmware Field/Value table of MEA's console default output (`default-output
/// -map.md` §2, one block, in ledger order), then the analysis's messages
/// (`issues`, ≈ the console message list §5) as their own block.
///
/// This is the pure target's summary entry point, mirroring `MEACurator`: the
/// controller never reads the model, it only lays out what `build` returns.
/// Every value is formatted here (with `MEAText`, the one shared voice) or
/// flagged `.comingSoon` when the row's fact is not in the model yet.
///
/// The honesty rule a row lives by: a row that is **always** answerable
/// (Family / Version / Release / Size) shows its value; a row whose fact the
/// model carries only sometimes shows `.comingSoon` when that fact is absent —
/// but only once the image is *identified* (`manifest != nil`), because a
/// roadmap of promised rows means nothing on a file the engine could not name.
/// Rows whose gate is not provable from the model are omitted entirely, exactly
/// as MEA omits them by its own gates.
public enum MEASummary {
    /// The summary blocks in reading order. The firmware table is always first
    /// and always non-empty; the messages block follows only when `issues`
    /// raised something.
    public static func build(_ analysis: FirmwareAnalysis) -> [MEASummaryBlock] {
        var rows: [MEASummaryRow] = []
        let add = { (label: String, value: MEASummaryValue) in
            rows.append(MEASummaryRow(label, value))
        }
        // The engine identified the image (manifest facts decoded). Only then
        // do rows the engine does not answer yet get promised as "Coming soon".
        let identified = analysis.manifest != nil

        // 1 · Family — always.
        add("Family", .value(MEAText.family(analysis.family)))
        // 2 · Version — always.
        add("Version", .value(analysis.version.text))
        // 3 · Release — always; engineering builds say so.
        var release = MEAText.title(analysis.release.rawValue)
        if analysis.version.build >= 7000 { release += ", Engineering" }
        add("Release", .value(release))

        // 4 · Type — Stock / Update / Extracted classifier not wired yet.
        if identified { add("Type", .comingSoon) }
        // 5 · SKU.
        if !analysis.sku.isEmpty {
            add("SKU", .value(analysis.sku))
        } else if identified {
            add("SKU", .comingSoon)
        }
        // 6a · Chipset — the pch_init aggregation's last record, letters
        // comma-joined ("CNP/CMP-H B,A" from a "BA" record).
        if let chipset = chipsetCell(analysis.mfsVolume?.pchInit) {
            add("Chipset", .value(chipset))
        }
        // 6c · Chipset Stepping — a derived stepping letter, when the engine
        // had one (top-level is PMC-side today; a no-pch_init case is unwired).
        if let stepping = analysis.chipsetStepping, !stepping.isEmpty {
            add("Chipset Stepping", .value(stepping))
        }
        // 8 · TCB Security Version Number (manifest `svn`).
        if let tcb = analysis.securityVersion, !tcb.isEmpty {
            add("TCB Security Version Number", .value(tcb))
        } else if identified {
            add("TCB Security Version Number", .comingSoon)
        }
        // 9 · ARB Security Version Number.
        if let arb = analysis.arbSvn {
            add("ARB Security Version Number", .value(String(arb)))
        } else if identified {
            add("ARB Security Version Number", .comingSoon)
        }
        // 10 · Version Control Number.
        if let vcn = analysis.vcn {
            add("Version Control Number", .value(String(vcn)))
        } else if identified {
            add("Version Control Number", .comingSoon)
        }
        // 11 · Production Ready (manifest production-ready flag).
        if let ready = analysis.manifest?.productionReady {
            add("Production Ready", .value(MEAText.yesNo(ready)))
        } else if identified {
            add("Production Ready", .comingSoon)
        }
        // 14 · OEM Configuration — OEM-signed / partition / UTOK presence.
        if isOEMFamily(analysis.family), identified {
            add("OEM Configuration", .comingSoon)
        }
        // 15 · FWUpdate Support — needs the independent-image IUP scan.
        if analysis.family == .csme, analysis.version.major >= 12, identified {
            add("FWUpdate Support", .comingSoon)
        }
        // 16 · Date (manifest date).
        if let date = analysis.manufactureDate {
            add("Date", .value(MEAText.date(date)))
        } else if identified {
            add("Date", .comingSoon)
        }
        // 17 · File System State.
        if isMFSFamily(analysis.family) {
            if let state = analysis.mfsState {
                add("File System State", .value(MEAText.title(state.rawValue)))
            } else if identified {
                add("File System State", .comingSoon)
            }
        }
        // 18 · Size — always.
        add("Size", .value(MEAText.size(analysis.sizeBytes)))
        // 19 · Flash Image Tool — BPDT FIT version; row only on an IFWI image.
        if analysis.bootPartitions != nil {
            add("Flash Image Tool", .comingSoon)
        }

        var blocks: [MEASummaryBlock] = [MEASummaryBlock(title: nil, rows: rows)]
        if !analysis.issues.isEmpty {
            let messages = analysis.issues.map { issue in
                MEASummaryRow(MEAText.title(issue.severity.rawValue),
                              .value(issue.message))
            }
            blocks.append(MEASummaryBlock(title: "Messages", rows: messages))
        }
        return blocks
    }

    /// The 6a display cell: the last per-chipset aggregate record as
    /// `"<chipset> <letters,comma-joined>"` — the exact form of the console
    /// row — or just the chipset when it carried no stepping letters.
    private static func chipsetCell(_ pchInit: MFSPCHInit?) -> String? {
        guard let last = pchInit?.chipsets.last, !last.chipset.isEmpty else {
            return nil
        }
        let letters = last.steppings.map(String.init).joined(separator: ",")
        return letters.isEmpty ? last.chipset : "\(last.chipset) \(letters)"
    }

    /// Families whose firmware usually carries an OEM-signed/partition story
    /// (upstream's `CSME/CSTXE/CSSPS/TXE/GSC` variant gate).
    private static func isOEMFamily(_ family: FirmwareFamily) -> Bool {
        switch family {
        case .csme, .cstxe, .cssps, .txe, .gsc: return true
        case .me, .sps, .pmc, .pchc, .phy, .orom, .unknown: return false
        }
    }

    /// Families with a File System State row (upstream's CS*/GSC variant gate).
    private static func isMFSFamily(_ family: FirmwareFamily) -> Bool {
        switch family {
        case .csme, .cstxe, .cssps, .gsc: return true
        case .me, .txe, .sps, .pmc, .pchc, .phy, .orom, .unknown: return false
        }
    }
}
