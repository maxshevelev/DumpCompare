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

/// How a row's value is drawn — the colour intent the pure target decides
/// because only it knows the fact behind a value (e.g. a File System State's
/// status). The view resolves each tone into a theme-adapted `NSColor`; a row
/// carries `.standard` unless it says otherwise.
public enum MEASummaryTone: Sendable, Equatable {
    /// The ordinary label-colour value most rows carry.
    case standard
    /// A settled state — drawn green.
    case good
    /// A state in the middle of its lifecycle — drawn brown.
    case caution
    /// A failed state — drawn red.
    case bad
}

/// One Field/Value row of the summary — the same shape as `MEAField`, with the
/// not-yet-surfaced value added.
public struct MEASummaryRow: Sendable, Equatable {
    public var label: String
    public var value: MEASummaryValue
    /// How the value is drawn; `.standard` for rows with nothing to say in
    /// colour.
    public var tone: MEASummaryTone

    public init(_ label: String, _ value: MEASummaryValue,
                tone: MEASummaryTone = .standard) {
        self.label = label
        self.value = value
        self.tone = tone
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

        // 4 · Type — the Stock / Update / Extracted classifier. Only an
        // image that sits on that axis (`.stock`/`.update`/`.extracted`) shows a
        // value; a family outside it or an ME 2–7 sub-branch the classifier has
        // no oracle for stays `.region`/`.unknown` → grey.
        if identified, let axis = axisType(analysis.type) {
            add("Type", .value(axis))
        } else if identified {
            add("Type", .comingSoon)
        }
        // 5 · SKU.
        if !analysis.sku.isEmpty {
            add("SKU", .value(analysis.sku))
        } else if identified {
            add("SKU", .comingSoon)
        }
        // 6 · One chipset row, chosen the way upstream chooses: the pch_init
        // aggregation's last record when there is one (6a), else the derived
        // stepping letters (6c) — and, for an identified image with neither, a
        // promise, since the stepping upstream falls back to comes from a
        // database lookup this engine does not do yet.
        if hasChipsetRow(analysis) {
            if let chipset = chipsetCell(analysis.mfsVolume?.pchInit) {
                add("Chipset", .value(chipset))
            } else if let stepping = analysis.chipsetStepping, !stepping.isEmpty {
                add("Chipset Stepping", .value(stepping))
            } else if identified {
                add("Chipset Stepping", .comingSoon)
            }
        }
        // 7 · NVM Compatibility — the storage medium the firmware is built
        // for, from the R2 signed-package extension. Undefined (0) prints no
        // row, exactly as upstream's then-empty `nvm_db` gate does; a chain
        // with no R2 extension at all carries no fact and no row either.
        if let nvm = analysis.nvmCompatibility, nvm != 0 {
            add("NVM Compatibility", .value(MEAText.nvmCompatibility(nvm)))
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
        // 14 · OEM Configuration — OEM-signed key / OEMP / UTOK presence. The
        // OEM detector answers Yes/No for every identified OEM-family image;
        // nil (a non-OEM family or unidentified) keeps the row grey.
        if isOEMFamily(analysis.family), identified {
            if let oem = analysis.oemCustomized {
                add("OEM Configuration", .value(MEAText.yesNo(oem)))
            } else {
                add("OEM Configuration", .comingSoon)
            }
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
                rows.append(MEASummaryRow("File System State",
                                          .value(MEAText.title(state.rawValue)),
                                          tone: Self.tone(for: state)))
            } else if identified {
                add("File System State", .comingSoon)
            }
        }
        // 18 · Size — how far the firmware itself reaches from its `$FPT`,
        // which is the number the console prints and not the size of what was
        // handed to the engine (0x27C000 of firmware inside a 16 MiB dump).
        // Where that cannot be worked out — no `$FPT`, or an ME 2–6 table that
        // leaves the last partition's size out — the row falls back to the
        // length of the region analysed, which is the only size there is.
        add("Size", .value(MEAText.size(analysis.firmwareSizeBytes
                                        ?? analysis.sizeBytes)))
        // 19 · Flash Image Tool — the FIT the image was built with. On an IFWI
        // image it is the first boot BPDT that carries a real FIT version
        // (`fitMajor` outside the 0/0xFFFF marker); a boot with no real FIT
        // reads "N/A", exactly as upstream's BPDT header print does. On a
        // non-IFWI image the value is the `$FPT` header's FIT (`fptHeaderFIT`)
        // — present only when the classifier resolved the image to Extracted
        // by that real FIT (upstream sets `fitc_ver_found` in that branch
        // alone, MEA.py 12581–12586), so a Stock / Update / SPS / ME 2–7
        // image gets no row at all.
        if let boot = analysis.bootPartitions {
            if let fit = boot.first(where: { $0.fitMajor != nil }),
               let major = fit.fitMajor, let minor = fit.fitMinor,
               let hotfix = fit.fitHotfix, let build = fit.fitBuild {
                add("Flash Image Tool", .value(MEAText.firmwareImageTool(
                    family: analysis.family, major: major, minor: minor,
                    hotfix: hotfix, build: build)))
            } else {
                add("Flash Image Tool", .value("N/A"))
            }
        } else if let fit = analysis.fptHeaderFIT {
            add("Flash Image Tool", .value(MEAText.firmwareImageTool(
                family: analysis.family, major: fit.major, minor: fit.minor,
                hotfix: fit.hotfix, build: fit.build)))
        }

        // 20 · Manifest Extension Utility — the MEU build stamped into the
        // manifest. R0 manifests reuse those bytes for SVN/VCN and carry none,
        // and a zero or 0xFFFF major is the "no MEU" marker upstream skips the
        // row on (MEA.py 12227) — so this row appears only where the console's
        // does, and is not promised anywhere else.
        if let meu = meuVersion(analysis.version) {
            add("Manifest Extension Utility", .value(meu))
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

    /// The MEU version of a manifest, or nil when it carries none: an R0
    /// manifest (no MEU block at all — the fields decode as nil) and the
    /// 0 / 0xFFFF markers both mean "not built by MEU".
    private static func meuVersion(_ version: Version) -> String? {
        guard let major = version.meMajor, major != 0, major != 0xFFFF,
              let minor = version.meMinor,
              let hotfix = version.meHotfix,
              let build = version.meBuild
        else { return nil }
        return MEAText.manifestExtensionUtility(
            major: major, minor: minor, hotfix: hotfix, build: build)
    }

    /// Whether the image gets a Chipset / Chipset Stepping row at all —
    /// upstream's `variant.startswith(('CS','PMC','GSC'))` minus the `PMCDG`
    /// exception (MEA.py 13700). A PCHC or PHY image has no chipset row, and
    /// neither has a pre-CSE ME/TXE/SPS one.
    private static func hasChipsetRow(_ analysis: FirmwareAnalysis) -> Bool {
        guard !analysis.variant.hasPrefix("PMCDG") else { return false }
        switch analysis.family {
        case .csme, .cstxe, .cssps, .pmc, .gsc: return true
        case .me, .txe, .sps, .pchc, .phy, .orom, .unknown: return false
        }
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

    /// The File System State row's colour tone. The two settled states — the
    /// volume has no files yet (`unconfigured`) and it is fully set up
    /// (`configured`) — read as green; a volume mid-lifecycle (`initialized`)
    /// is brown; a failed decode (`error`) is red.
    private static func tone(for state: MFSState) -> MEASummaryTone {
        switch state {
        case .unconfigured, .configured: return .good
        case .initialized: return .caution
        case .error: return .bad
        }
    }

    /// The Stock / Update / Extracted axis word for a firmware `type`, nil when
    /// the type is not on the axis — `.region` (a raw region the engine did not
    /// classify) or `.unknown` (a family outside the axis, or an ME 2–7
    /// sub-branch the classifier has no oracle for). Those stay grey.
    private static func axisType(_ type: FirmwareType) -> String? {
        switch type {
        case .stock: return "Stock"
        case .update: return "Update"
        case .extracted: return "Extracted"
        case .region, .unknown: return nil
        }
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
