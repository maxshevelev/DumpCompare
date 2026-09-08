import XCTest
import Foundation
@testable import MEFirmware

/// Phase 12 — Independent (IUP) PMC/PCHC/PHY descriptor facts, ported from
/// upstream `pmc_anl`/`pchc_anl`/`phy_anl` (MEA.py 9164/9277/9342) plus the
/// main-summary row gating (13768/13774). Expected values for the TGP rows are
/// the actual ones upstream MEA.py v1.312.0 prints for the three real 1.bin
/// IUP partitions (PMC 150.2.10.1015 → Chipset SKU H / Stepping B / Support TGP;
/// PCHC 15.0.0.1020 → Support TGP only; PHY 15.105.135.5012 → SKU N / Support
/// TGP). Tests never touch the network.
final class IUPDescriptorTests: XCTestCase {

    private func facts(_ family: FirmwareFamily, _ variant: String,
                       major: Int, minor: Int = 0, hotfix: Int = 0) -> IUPDescriptor.Facts? {
        IUPDescriptor.facts(family: family, variant: variant,
                            major: major, minor: minor, hotfix: hotfix)
    }

    // ——— Oracle rows (real MEA.py on the 1.bin IUP partitions) ———

    func testOraclePMCTGP() throws {
        // PMC 150.2.10.1015 → TGP: SKU H (minor 2), stepping B (hotfix 10//10).
        let f = try XCTUnwrap(facts(.pmc, "PMCTGP", major: 150, minor: 2, hotfix: 10))
        XCTAssertEqual(f.platform, "TGP")
        XCTAssertEqual(f.sku, "H")
        XCTAssertEqual(f.chipsetStepping, "B")
    }

    func testOraclePCHCTGP() throws {
        // PCHC 15.0.0.1020 → TGP: platform only, no SKU/stepping.
        let f = try XCTUnwrap(facts(.pchc, "PCHCTGP", major: 15))
        XCTAssertEqual(f.platform, "TGP")
        XCTAssertNil(f.sku)
        XCTAssertNil(f.chipsetStepping)
    }

    func testOraclePHYNTGP() throws {
        // PHY 15.105.135.5012 → TGP: SKU from the 4th token char (N).
        let f = try XCTUnwrap(facts(.phy, "PHYNTGP", major: 15))
        XCTAssertEqual(f.platform, "TGP")
        XCTAssertEqual(f.sku, "N")
        XCTAssertNil(f.chipsetStepping)
    }

    // ——— General PMC SKU-by-minor branches ———

    func testPMCGeneralSKUByMinor() {
        // pch_sku_val {0:'SoC',1:'LP',2:'H',3:'N',4:'M'} — minor drives the SKU.
        XCTAssertEqual(facts(.pmc, "PMCICP", major: 130, minor: 1)?.sku, "LP")
        XCTAssertEqual(facts(.pmc, "PMCLKF", major: 140, minor: 2)?.sku, "H")
        XCTAssertEqual(facts(.pmc, "PMCJSP", major: 130, minor: 3)?.sku, "N")
        // Minor outside 0..4 leaves the SKU unknown (nil).
        XCTAssertNil(facts(.pmc, "PMCTGP", major: 150, minor: 9)?.sku)
    }

    func testPMCPlatformFromTokenSuffix() {
        // Non-special tokens: platform = last 3 chars of the variant.
        XCTAssertEqual(facts(.pmc, "PMCICP", major: 130)?.platform, "ICP")
        XCTAssertEqual(facts(.pmc, "PMCLKF", major: 140)?.platform, "LKF")
        XCTAssertEqual(facts(.pmc, "PMCJSP", major: 130)?.platform, "JSP")
    }

    // ——— Special PMC token branches ———

    func testPMCCMPV() {
        // CMP-V (KBP): SKU V, platform label CMP-V, stepping stays hotfix-based.
        let f = facts(.pmc, "PMCCMPV", major: 145, minor: 0, hotfix: 0)
        XCTAssertEqual(f?.platform, "CMP-V")
        XCTAssertEqual(f?.sku, "V")
    }

    func testPMCWTL() {
        // Whitley: SKU H, stepping B, platform WTL.
        let f = facts(.pmc, "PMCWTL", major: 150, minor: 0, hotfix: 30)
        XCTAssertEqual(f?.platform, "WTL")
        XCTAssertEqual(f?.sku, "H")
        XCTAssertEqual(f?.chipsetStepping, "B")
    }

    func testPMCAPLBXTGLK() {
        // APL/BXT/GLK: platform = token[3:6], stepping = token's last char, no SKU.
        let apl = facts(.pmc, "PMCAPLP", major: 130, minor: 0)
        XCTAssertEqual(apl?.platform, "APL")
        XCTAssertEqual(apl?.chipsetStepping, "P")
        XCTAssertNil(apl?.sku)

        let bxt = facts(.pmc, "PMCBXT", major: 130)
        XCTAssertEqual(bxt?.platform, "BXT")
        XCTAssertEqual(bxt?.chipsetStepping, "T")
        XCTAssertNil(bxt?.sku)
    }

    func testPMCSteppingLetterFromHotfix() {
        // Default stepping letter = pch_rev_val[min(hotfix/10, 0xF)].
        XCTAssertEqual(facts(.pmc, "PMCTGP", major: 150, hotfix: 30)?.chipsetStepping, "D")
        XCTAssertEqual(facts(.pmc, "PMCTGP", major: 150, hotfix: 5)?.chipsetStepping, "A")
        // Hotfix clamped to index 15 ('P').
        XCTAssertEqual(facts(.pmc, "PMCTGP", major: 150, hotfix: 200)?.chipsetStepping, "P")
    }

    // ——— Family / token gating ———

    func testNonIUPFamilyReturnsNil() {
        XCTAssertNil(IUPDescriptor.facts(family: .csme, variant: "CSME",
                                         major: 15, minor: 0, hotfix: 30))
        XCTAssertNil(IUPDescriptor.facts(family: .unknown, variant: "PMC",
                                         major: 150, minor: 0, hotfix: 10))
    }

    func testUnknownOrShortTokenReturnsNil() {
        XCTAssertNil(facts(.pmc, "Unknown", major: 150))
        XCTAssertNil(facts(.pchc, "PC", major: 15))    // too short for a 3-char suffix
        XCTAssertNil(facts(.phy, "PHY", major: 15))    // too short for the SKU char
    }

    func testPCHCCMPV() {
        XCTAssertEqual(facts(.pchc, "PCHCCMPV", major: 15)?.platform, "CMP-V")
    }

    func testPHYDGAlwaysG() {
        // PHYDG prefix: SKU always G, platform from the token suffix.
        let f = facts(.phy, "PHYDG1", major: 15)
        XCTAssertEqual(f?.sku, "G")
        XCTAssertEqual(f?.platform, "DG1")
    }
}
