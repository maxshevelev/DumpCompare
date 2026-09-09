import Foundation

/// Descriptor facts for the Independent (IUP) firmware families — PMC, PCHC
/// and PHY — surfaced on a bare IUP partition region. Mirrors upstream
/// `pmc_anl` (MEA.py 9164), `pchc_anl` (9277) and `phy_anl` (9342), which take
/// the manifest identity of the single operational `$CPD` and derive:
///
/// - `platform` — the *Chipset Support* label (e.g. `TGP`, `CMP-V`, `WTL`),
///   i.e. the PCH/chipset the firmware is built for;
/// - `sku` — the *Chipset SKU* letter for PMC/PHY (e.g. `H`, `LP`, `N`, `V`),
///   when the family derives one (PCHC never does);
/// - `chipsetStepping` — the PMC *chipset stepping* letter (e.g. `B`) decoded
///   from the manifest hotfix/major. PCHC and PHY surface none.
///
/// All three only exist for a recognised IUP token; the top-level CSE-family
/// `platform`/`sku` are unrelated (see `Identify/SKU.swift`, and the MFS
/// PCH-init decode which feeds the CSE `platform`).
enum IUPDescriptor {
    struct Facts: Equatable {
        var platform: String        // Chipset Support
        var sku: String?            // Chipset SKU letter (PMC/PHY) or nil
        var chipsetStepping: String?  // PMC chipset stepping letter or nil
    }

    /// The `pch_rev_val` letter table of `pmc_anl` (index 0..15 → 'A'..'P').
    private static let steppingLetters = Array("ABCDEFGHIJKLMNOP")

    /// `pch_rev_val[min(hotfix / 10, 0xF)]` — the default stepping letter.
    private static func steppingLetter(hotfix: Int) -> Character {
        steppingLetters[min(hotfix / 10, 0xF)]
    }

    /// `pch_sku_val {0:'SoC',1:'LP',2:'H',3:'N',4:'M'}` — the general-branch
    /// Chipset SKU by the manifest minor; nil when minor is outside 0..4.
    private static func skuByMinor(_ minor: Int) -> String? {
        ["SoC", "LP", "H", "N", "M"].indices.contains(minor)
            ? ["SoC", "LP", "H", "N", "M"][minor] : nil
    }

    /// Derive the IUP descriptor facts for an identified IUP family. Returns
    /// nil for non-IUP families (the caller keeps the CSE/CSME SKU path) and
    /// for unidentified tokens (family `.unknown`).
    static func facts(family: FirmwareFamily, variant: String,
                      major: Int, minor: Int, hotfix: Int) -> Facts? {
        switch family {
        case .pmc:  return pmc(variant: variant, major: major,
                               minor: minor, hotfix: hotfix)
        case .pchc: return pchc(variant: variant)
        case .phy:  return phy(variant: variant)
        default:    return nil
        }
    }

    /// `pmc_anl`: platform defaults to the last 3 token chars (`PMCTGP` → `TGP`);
    /// stepping defaults to `pch_rev_val[min(hotfix/10, 0xF)]`; then per-token
    /// overrides for CNP (pre-12 stepping from major, old SKU H/LP), CMP-V
    /// (SKU V), WTL (SKU H / stepping B), APL/BXT/GLK (platform `token[3:6]`,
    /// stepping = token last char, no SKU), else the general SKU by minor.
    private static func pmc(variant: String, major: Int, minor: Int,
                            hotfix: Int) -> Facts? {
        guard variant.count >= 3, variant != "Unknown" else { return nil }

        var platform = String(variant.suffix(3))
        var stepping = steppingLetter(hotfix: hotfix)
        var sku: String? = nil

        if variant == "PMCCNP", ![300, 30].contains(major) {
            // Pre-12.0.0.1033 CNP: old SKU naming from hotfix, stepping from major.
            // pch_sku_old {0:'H', 2:'LP'} — hotfix outside those leaves SKU unknown.
            if hotfix == 0 { sku = "H" }
            else if hotfix == 2 { sku = "LP" }
            stepping = steppingLetters[min(major / 10, 0xF)]
        } else if variant == "PMCCMPV" {
            sku = "V"
            platform = "CMP-V"
        } else if variant == "PMCWTL" {
            sku = "H"
            stepping = "B"
            platform = "WTL"
        } else if variant.hasPrefix("PMCAPL") || variant.hasPrefix("PMCBXT")
                    || variant.hasPrefix("PMCGLK") {
            platform = String(variant.dropFirst(3).prefix(3))
            stepping = variant.last ?? "?"
        } else if let skuByMinor = Self.skuByMinor(minor) {
            // General branch: pch_sku_val {0:'SoC',1:'LP',2:'H',3:'N',4:'M'}
            sku = skuByMinor
        }

        // Main-summary display gating (MEA.py 13768/13774): the SKU row is only
        // printed when the token is not an APL/BXT/GLK/DG part (those carry no
        // Chipset SKU), and the Chipset Stepping row is printed for every PMC
        // except the DG prefix. Mirror those here so the facts equal the rows
        // upstream actually renders.
        if variant.hasPrefix("PMCAPL") || variant.hasPrefix("PMCBXT")
            || variant.hasPrefix("PMCGLK") || variant.hasPrefix("PMCDG") {
            sku = nil
        }
        let steppingShown = !variant.hasPrefix("PMCDG")
        return Facts(platform: platform, sku: sku,
                     chipsetStepping: steppingShown ? String(stepping) : nil)
    }

    /// `pchc_anl`: platform is `CMP-V` for the PCHCCMPV token, else the last 3
    /// token chars. PCHC derives no SKU and no stepping.
    private static func pchc(variant: String) -> Facts? {
        guard variant.count >= 3, variant != "Unknown" else { return nil }
        let platform = variant == "PCHCCMPV" ? "CMP-V" : String(variant.suffix(3))
        return Facts(platform: platform, sku: nil, chipsetStepping: nil)
    }

    /// `phy_anl`: platform = last 3 token chars; SKU = 4th token char, except
    /// the `PHYDG` prefix which is always `G`. No stepping.
    private static func phy(variant: String) -> Facts? {
        guard variant.count >= 4, variant != "Unknown" else { return nil }
        let platform = String(variant.suffix(3))
        let sku = variant.hasPrefix("PHYDG") ? "G" : String(variant.dropFirst(3).first!)
        return Facts(platform: platform, sku: sku, chipsetStepping: nil)
    }
}
