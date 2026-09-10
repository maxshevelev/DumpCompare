import Foundation

/// `get_variant`'s module-name fallback (MEA.py 10344–10396): when no database
/// RSA public key claims a manifest, the modules of its own `$CPD` name the
/// firmware. That is how every stitched independent firmware is recognised —
/// Intel does not publish a key line for each PMC/PCHC/PHY — and how a CSME or
/// (CS)SPS image signed with an unpublished key still gets a family.
///
/// The rules are upstream's, in upstream's order: one pass over the module
/// names, each match *assigning* the variant with no break, so the last
/// module that matches decides. Most rules pair a module name with the
/// firmware's own major (and sometimes the MEU version behind it), which is
/// what tells one platform's PMC from another's — every PMC carries a module
/// called `PMCC000`.
///
/// `isMEU` is upstream's `is_meu` (the manifest has MEU fields at all — R1/R2,
/// never R0), and `year` is the manifest's calendar year: upstream compares the
/// raw BCD word against `0x2017`, which is the same test as "2017 or earlier"
/// on the decoded number.
///
/// Not ported: the two branches that follow this one when the `$CPD` has no
/// modules to read — a `$MME` directory at a fixed distance past the manifest
/// (TXE) and two `$SKU` byte patterns (SPS). Both name pre-CSE families that
/// the shared ME/TXE key already covers here.
enum VariantByModule {
    /// The variant token the modules name, or nil when none of them does.
    static func variant(moduleNames: [String], major: Int, minor: Int,
                        year: Int, meuMajor: Int?, meuMinor: Int?) -> String? {
        let isMEU = meuMajor != nil
        var found: String?
        for module in moduleNames {
            if module == "fwupdate" { found = "CSME" }
            else if ["bup_rcv", "sku_mgr", "manuf"].contains(module) { found = "CSSPS" }
            else if module.hasPrefix("dkl"), major == 10, isMEU, meuMajor == 13 {
                found = "PHYSLKF"
            } else if module.hasPrefix("dkl"), major == 11 || major == 0,
                      isMEU, meuMajor == 100 {
                found = "PHYDG1"
            } else if module.hasPrefix("PCIE"), major == 11 || major == 0,
                      isMEU, meuMajor == 101 {
                found = "PHYDG2"
            } else if module == "gen4_i", [13, 14].contains(major),
                      isMEU, meuMajor == 16 {
                found = "PHYNADP"
            } else if module == "SNPMULTI", major == 13, isMEU, meuMajor == 16 {
                found = "PHYSADP"
            } else if module == "nphy", [9, 7].contains(major), isMEU, meuMajor == 13 {
                found = "PHYNICP"
            } else if module == "nphy", [16, 15, 11].contains(major),
                      isMEU, meuMajor == 15 {
                found = "PHYNTGP"
            } else if module == "pphy", [12, 14, 11].contains(major),
                      isMEU, meuMajor == 15 {
                found = "PHYPTGP"
            } else if module == "pphy", major == 12, isMEU, meuMajor == 0 {
                found = "PHYPEBG"
            } else if module == "pphy", major == 12 || major == 0 {
                found = "PHYPCMP"
            } else if module == "IntelRec", major == 16 { found = "PCHCADP" }
            else if module == "IntelRec", major == 15, isMEU, meuMinor == 40 {
                found = "PCHCMCC"
            } else if module == "IntelRec", major == 15, isMEU, meuMinor == 0 {
                found = "PCHCTGP"
            } else if module == "IntelRec", (major, minor) == (14, 5) { found = "PCHCCMPV" }
            else if module == "IntelRec", (major, minor) == (14, 0) { found = "PCHCCMP" }
            else if module == "IntelRec", (major, minor) == (13, 30) { found = "PCHCLKF" }
            else if module == "IntelRec", (major, minor) == (13, 5) { found = "PCHCJSP" }
            else if module == "IntelRec", (major, minor) == (13, 0) { found = "PCHCICP" }
            else if module == "PMCC000",
                    [300, 30, 3232].contains(major) || (major < 30 && year <= 2017) {
                found = "PMCCNP"
            } else if module == "PMCC000", major == 133 { found = "PMCLKF" }
            else if module == "PMCC000", [135, 130].contains(major), isMEU, meuMinor == 50 {
                found = "PMCJSP"
            } else if module == "PMCC000", [400, 130].contains(major) { found = "PMCICP" }
            else if module == "PMCC000", major == 140, isMEU, meuMinor == 5 {
                found = "PMCCMPV"
            } else if module == "PMCC000", major == 140 { found = "PMCCMP" }
            else if module == "PMCC000", major == 150 { found = "PMCTGP" }
            else if module == "PMCC000", major == 154 { found = "PMCMCC" }
            else if module == "PMCC000", major == 160 { found = "PMCADP" }
            else if module == "PMCC000", major == 1, !isMEU { found = "PMCWTL" }
            else if module == "PMCC000", major == 14 { found = "PMCIDV" }
            else if module == "PMCC002" { found = "PMCAPLA" }
            else if module == "PMCC003" { found = "PMCAPLB" }
            else if module == "PMCC004" { found = "PMCGLKA" }
            else if module == "PMCC005" { found = "PMCBXTC" }
            else if module == "PMCC006" { found = "PMCGLKB" }
            else if ["gfx_srv", "chassis"].contains(module) { found = "GSC" }
            else if module.hasPrefix("PCOD"), isMEU, meuMajor == 100 { found = "PMCDG1" }
            else if module.hasPrefix("PCOD"), isMEU,
                    major == 4 || major == 2 || meuMajor == 101 {
                found = "PMCDG2"
            } else if module == "VBT", major == 19 { found = "OROMDG1" }
            else if module == "VBT", major == 20 { found = "OROMDG2" }
            else if module == "VBT" { found = "OROM" }
        }
        // With modules present but none of them recognised, these two versions
        // are a CSTXE (10395).
        if found == nil, !moduleNames.isEmpty,
           (major, minor) == (4, 0) || (major, minor) == (3, 0) {
            found = "CSTXE"
        }
        return found
    }
}
