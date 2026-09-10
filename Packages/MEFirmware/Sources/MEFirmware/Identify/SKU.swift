import Foundation

/// CSME 12+ SKU composition — the `SKU` row of the upstream summary
/// (e.g. `Consumer H`). A faithful port of three upstream pieces:
///
/// - the main-flow SKU-Type selection (MEA.py 13061): pick the label from
///   `CSE_Ext_0C`'s SKUType (`ext12_fw_sku`) unless `CSE_Ext_0F_R2` carries a
///   *meaningful* Firmware SKU (`ext15_fw_sku`). `0x0F_R2`'s reserved 1 /
///   Corporate-holder values and `CON`/`COR`/`NA`/`ALL` are ignored so the real
///   `0x0C` value wins (`CON`, `COR` are the confusing placeholders 0x0F_R2
///   shipped early).
/// - `get_cse_db` (MEA.py 10262) CSME cells: the matched MEA.dat row supplies
///   the PCH platform (cell 2) and stepping (cell 3) — a DB match *overrides*
///   the extension-derived platform.
/// - `get_csme12_sku` (MEA.py 10287): resolve the platform letter, then compose
///   `"<type name> <platform>"`. Resolution order when there is no DB match:
///   MFS PCH-init table (not ported — needs the MFS *file* walk, rows 66–67 of
///   upstream-map), then the CSME 12.0.0-alpha `SKUPlatform` field, then the
///   `FWSKUCaps` bit 8 `H` / bit 9 `LP` labels (`skuc_dict`), with the CSME
///   14.5 `H→V` and 13 Slim-`LP→N` corrections applied on that last path.
///
/// CSME 11 composes the same label with a platform letter of its own
/// (MEA.py 13091–13130): from 11.0.0.1205 the `CSE_Ext_0C` SKU Platform field
/// says it outright (0 Halo, 1 Low Power), and only an older build sends
/// upstream into the Huffman-decompressed `kernel` module for a byte pattern —
/// that scan is not ported, and such a firmware falls back to the database row
/// as upstream's last resort does. Note the order is the other way round from
/// CSME 12+: there the database *overrides* the extensions, here it only fills
/// in for them.
///
/// Other families are left to a future increment. The inputs are the *decoded*
/// `CSE_Ext_0C`/`CSE_Ext_0F_R2` facts plus the canonical MEA.dat row — no byte
/// reading, so every branch is unit-testable.
enum SKU {
    /// A pair of human label + short database code.
    typealias Label = (display: String, code: String)

    /// `ext12_fw_sku` (MEA.py 10572): `CSE_Ext_0C` SKUType code → label.
    private static let ext12: [Int: Label] = [
        0: ("Corporate", "COR"),
        1: ("Consumer", "CON"),
        2: ("Slim", "SLM"),
        3: ("Server", "SVR"),
        5: ("Chrome", "CHR"),
    ]

    /// `ext15_fw_sku` (MEA.py 10581): `CSE_Ext_0F_R2` Firmware SKU code → label.
    private static let ext15: [Int: Label] = [
        0: ("Undefined", "NA"),
        1: ("Corporate", "COR"),
        2: ("Consumer", "CON"),
        3: ("Slim", "SLM"),
        4: ("Lite", "LIT"),
        5: ("Server", "SVR"),
        6: ("Atom", "ATM"),
        255: ("All", "ALL"),
    ]

    /// The decoded facts the composition needs — mirrors the upstream globals
    /// (`variant`, `major…month`, `fw_0C_*` from `ext12_info`, `ext15_info[2]`
    /// and the `get_cse_db` return).
    struct Facts {
        var variant: String
        var major: Int
        var minor: Int
        var hotfix: Int
        var build: Int
        var year: Int
        var month: Int

        /// `CSE_Ext_0C.SKUType` (3 bits); nil when the chain carries no 0x0C.
        var skuType: Int?
        /// `CSE_Ext_0C.FWSKUCaps` raw bitmask (bits 8 `H`, 9 `LP`).
        var skuCaps: Int?
        /// `CSE_Ext_0C.SKUPlatform` (2 bits); only meaningful for CSME 11 /
        /// CSME 12.0.0-alpha.
        var skuPlatform: Int?
        /// `CSE_Ext_0F_R2.FWSKU` (3 bits); nil when 0x0F is absent or not an R2
        /// header.
        var fwSku: Int?
        /// The canonical MEA.dat firmware row (`…_CON_H_BA_PRD_RGN_<hash>`), nil
        /// when the firmware is not in the database.
        var databaseRow: String?
    }

    /// Compose the CSME 12+ `SKU` string, or nil when there is no determinate
    /// value (non-CSME / CSME 11 / no SKU-type source to name the SKU with).
    static func csme(_ f: Facts) -> String? {
        guard f.variant == "CSME", f.major >= 11 else { return nil }

        // ——— SKU-Type label (main flow 13061): 0x0C unless 0x0F_R2 differs
        // meaningfully. Absent blocks read as an empty label, so a genuine
        // "no 0x0C, no 0x0F" chain yields nothing to name the SKU with.
        let ocLabel: Label = f.skuType.flatMap { ext12[$0] } ?? (f.skuType == nil ? ("", "") : ("Unknown", "UNK"))
        let ofLabel: Label = f.fwSku.flatMap { ext15[$0] } ?? (f.fwSku == nil ? ("", "") : ("Unknown", "UNK"))

        let type: Label
        if ocLabel.code != "UNK" && ["", "NA", "ALL", "CON", "COR", "ATM"].contains(ofLabel.code) {
            type = ocLabel
        } else if !["", "NA", "ALL"].contains(ofLabel.code) {
            type = ofLabel
        } else {
            type = ("Unknown", "UNK")
        }
        guard !type.display.isEmpty else { return nil }

        // ——— CSME 11's own platform letter, extension first.
        if f.major == 11 {
            guard let letter = csme11Platform(f) else { return nil }
            return "\(type.display) \(letter)"
        }

        // ——— Platform letter (`get_cse_db` + `get_csme12_sku`).
        var platform: String
        if let row = f.databaseRow {
            // A DB match sets sku != 'NaN', so the DB's PCH platform overrides
            // every extension/MFS source (get_cse_db CSME cell 2).
            platform = platformCell(row) ?? "Unknown"
        } else if isCSME12Alpha(f) {
            // CSME 12.0.0 alpha only: SKUPlatform 00 = H, 01 = LP.
            platform = [0: "H", 1: "LP"][f.skuPlatform ?? -1] ?? "Unknown"
        } else {
            // SKU Capabilities (skuc_dict): bit 9 = LP, bit 8 = H; LP wins if
            // both are set (upstream checks 'LP' before 'H').
            if let caps = f.skuCaps {
                if caps & (1 << 9) != 0 { platform = "LP" }
                else if caps & (1 << 8) != 0 { platform = "H" }
                else { platform = "Unknown" }
            } else {
                platform = "Unknown"
            }
            // Corrections applied only on this extension-derived path.
            if (f.major, f.minor, platform) == (14, 5, "H") { platform = "V" }          // CSME 14.5 H → V
            else if f.major == 13, type.display == "Slim", platform == "LP" { platform = "N" }  // CSME 13 SLM LP → N
        }

        return "\(type.display) \(platform)"
    }

    /// CSME 11's platform letter: the `CSE_Ext_0C` SKU Platform field on
    /// 11.0.0.1205 and later (0 Halo, 1 Low Power), else the database row's
    /// own cell. nil when neither says one — an older build, whose letter
    /// upstream reads out of the decompressed `kernel` module, a scan that is
    /// not ported.
    private static func csme11Platform(_ f: Facts) -> String? {
        let extensionSaysIt = f.minor > 0
            || f.hotfix > 0
            || (f.build >= 1205 && f.build != 7101)
        if extensionSaysIt, let letter = [0: "H", 1: "LP"][f.skuPlatform ?? -1] {
            return letter
        }
        return f.databaseRow.flatMap(platformCell)
    }

    /// The PCH platform cell of a CSME database row (`get_cse_db` cell 2).
    private static func platformCell(_ row: String) -> String? {
        let cells = row.split(separator: "_", omittingEmptySubsequences: false)
        guard cells.count > 2, !cells[2].isEmpty else { return nil }
        return String(cells[2])
    }

    /// CSME 12.0.0-alpha gate of `get_csme12_sku`: pre-2018-08 engineering
    /// builds (build ≥ 7000) read the platform from the 0x0C `SKUPlatform`
    /// field instead of the capabilities.
    private static func isCSME12Alpha(_ f: Facts) -> Bool {
        (f.major, f.minor, f.hotfix) == (12, 0, 0)
            && f.build >= 7000 && f.year < 0x2018 && f.month < 8
    }
}
