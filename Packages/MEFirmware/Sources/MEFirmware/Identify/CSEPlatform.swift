import Foundation

/// Row 22's Chipset Support (upstream `platform`) for the CSE families: the
/// PCH or SoC the firmware is built for, named from its own version.
///
/// Upstream keeps this as a per-family literal table in the main flow (MEA.py
/// 13137–13140 for CSME 11 and 13175–13200 for 12–16, 13291–13311 for CSTXE),
/// and for CSME it names a platform **only when the image carries no chipset
/// initialisation table**: where one exists the Chipset row already says which
/// chipset and stepping the firmware initialises, and upstream leaves
/// `platform` at its `'NaN'` default so the summary prints no Chipset Support
/// row at all. That gate is why the row is absent on three of the four CSME
/// oracles and present as "ADP/RPP" on the CSME-16 one, whose FTBL-mode file
/// system has no such table.
///
/// Not ported: the (CS)SPS names, which upstream picks from the `CSE_Ext_50`
/// SKU-platform cell before falling back to the initialisation table
/// (13408–13429), and the GSC ones. Those families come back nil, and the row
/// then stays off the table rather than showing a guess.
enum CSEPlatformNames {
    /// What is known about the image's chipset initialisation table — the
    /// thing whose presence decides whether a CSME platform is named at all.
    ///
    /// `.unknown` is the honest answer for a file-table (FTBL) volume that
    /// holds files: upstream decodes its configuration with `FileTable.dat`
    /// and would find any initialisation table in it, this engine does not yet
    /// — so it cannot say the table is absent, and must not name a platform
    /// upstream would leave unnamed (measured: the CSME-15 oracle, whose
    /// console prints "Chipset TGP/EBG-H A" and no Chipset Support row).
    enum ChipsetInitTable {
        case present, absent, unknown
    }

    /// The platform name, or nil when this family and version name none —
    /// upstream's `'NaN'`, the state that prints no row.
    static func name(family: FirmwareFamily, major: Int, minor: Int,
                     chipsetInitTable: ChipsetInitTable) -> String? {
        switch family {
        case .csme:
            // The chipset initialisation table, where there is one, is the
            // better answer and takes the row instead.
            guard chipsetInitTable == .absent else { return nil }
            return csme(major: major, minor: minor)
        case .cstxe:
            return cstxe(major: major, minor: minor)
        default:
            return nil
        }
    }

    private static func csme(major: Int, minor: Int) -> String? {
        switch (major, minor) {
        case (11, 0): return "SPT"                        // Sunrise Point
        case (11, 5), (11, 6), (11, 7), (11, 8): return "SPT/KBP"  // …, Union Point
        case (11, 10), (11, 11), (11, 12): return "BSF/GCF"        // Basin/Glacier Falls
        case (11, 20), (11, 21), (11, 22): return "LBG"            // Lewisburg
        case (12, 0): return "CNP"                        // Cannon Point
        case (13, 0): return "ICP"                        // Ice Point
        case (13, 30): return "LKF"                       // Lakefield
        case (13, 50): return "JSP"                       // Jasper Point
        case (14, 0), (14, 1): return "CMP-H/LP"          // Comet Point H/LP
        case (14, 5): return "CMP-V"                      // Comet Point V
        case (15, 0): return "TGP"                        // Tiger Point
        case (15, 40): return "MCC"                       // Mule Creek Canyon
        case (16, 0): return "ADP"                        // Alder Point
        case (16, 1): return "ADP/RPP"                    // Raptor Point
        default: return nil
        }
    }

    /// CSTXE names its platform whatever the file system holds — there is no
    /// initialisation-table gate on these three.
    private static func cstxe(major: Int, minor: Int) -> String? {
        switch (major, minor) {
        case (3, 0), (3, 1): return "APL"                 // Apollo Lake
        case (3, 2): return "BXT"                         // Broxton (Joule)
        case (4, 0): return "GLK"                         // Gemini Lake
        default: return nil
        }
    }
}
