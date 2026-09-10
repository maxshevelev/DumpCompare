import XCTest
import Foundation
@testable import MEFirmware

/// Phase 10 — CSME 12+ SKU composition (`SKU.csme`), ported from upstream
/// `get_cse_db` CSME cells + the main-flow 0x0C/0x0F SKU-Type selection +
/// `get_csme12_sku`. Expected strings are the actual rows upstream MEA.py v1.312.0
/// prints for the two real dumps (`SKU = Consumer H` on both CSME 12.0.3.1091 and
/// CSME 15.0.30.1716). Tests never touch the network.
final class SKUTests: XCTestCase {

    /// CSME 12.0.3.1091-style facts (production, non-alpha): 0x0C Consumer,
    /// capabilities bit 8 (H) set, no 0x0F.
    private static func facts(major: Int = 12, minor: Int = 0, hotfix: Int = 0,
                              build: Int = 1091, year: Int = 2018, month: Int = 5,
                              skuType: Int? = 1, skuCaps: Int? = (1 << 8),
                              skuPlatform: Int? = nil, fwSku: Int? = nil,
                              databaseRow: String? = nil) -> SKU.Facts {
        SKU.Facts(variant: "CSME", major: major, minor: minor, hotfix: hotfix,
                  build: build, year: year, month: month,
                  skuType: skuType, skuCaps: skuCaps, skuPlatform: skuPlatform,
                  fwSku: fwSku, databaseRow: databaseRow)
    }

    private static let csme12Row = "12.0.3.1091_CON_H_BA_PRD_RGN_94D786E6367B58B74A96DE80FB20EA7EE8D79367D78021CA2968D9B717439466"

    func testConsumerFromDBCell() throws {
        // The real dump: DB row cell 2 (H) overrides; label Consumer from 0x0C.
        XCTAssertEqual(SKU.csme(Self.facts(databaseRow: Self.csme12Row)), "Consumer H")
    }

    func testCapsFallbackWhenNotInDB() throws {
        // No DB row → platform from FWSKUCaps bit 8 (H).
        XCTAssertEqual(SKU.csme(Self.facts()), "Consumer H")
    }

    func testDBOverridesCaps() throws {
        // DB row claims LP while the capabilities advertise H → DB wins.
        let lpRow = "12.0.3.1091_CON_LP_B_PRD_RGN_C00085833191A5E8CDBC0EA5FE07AC62CC41C98CC6FD62476B7BC136CF852391"
        XCTAssertEqual(SKU.csme(Self.facts(databaseRow: lpRow)), "Consumer LP")
    }

    func testExt15PlaceholderCorporateIgnored() throws {
        // CSME 15 carries a 0x0F_R2 Firmware SKU of 1 (Corporate placeholder) —
        // ignored when 0x0C says Consumer, matching upstream's "Consumer H".
        let row = "15.0.30.1716_CON_H_A_PRD_RGN_CFE06D28C1385119BC38C360A8535D8C1FF7865E7FE5CB8B965BD056FA1B6DD8"
        XCTAssertEqual(SKU.csme(Self.facts(major: 15, minor: 0, build: 1716,
                                           year: 2019, fwSku: 1, databaseRow: row)),
                       "Consumer H")
    }

    func testExt15UsedWhenNo0x0C() throws {
        // No 0x0C block at all → the 0x0F_R2 Server (5) names the SKU.
        XCTAssertEqual(SKU.csme(Self.facts(skuType: nil, skuCaps: nil, fwSku: 5,
                                           databaseRow: "15.40.37.3121_SVR_LP_C_SPI_PRD_EXTR_AABB")),
                       "Server LP")
    }

    func testUnknownSKUTypeFromDB() throws {
        // 0x0C code outside the table → "Unknown"; DB platform still applies.
        XCTAssertEqual(SKU.csme(Self.facts(skuType: 7, databaseRow: Self.csme12Row)),
                       "Unknown H")
    }

    func testCapsLPWinsOverH() throws {
        // Both capability bits set → upstream checks 'LP' first.
        XCTAssertEqual(SKU.csme(Self.facts(skuCaps: (1 << 8) | (1 << 9))), "Consumer LP")
    }

    func testCSME145HAdjustsToV() throws {
        // CSME 14.5 caps-derived H is corrected to V (no DB override).
        XCTAssertEqual(SKU.csme(Self.facts(major: 14, minor: 5, build: 5000, year: 2019)),
                       "Consumer V")
    }

    func testCSME13SlimLPAdjustsToN() throws {
        // CSME 13 Slim on LP is corrected to N (no DB override).
        XCTAssertEqual(SKU.csme(Self.facts(major: 13, minor: 0, build: 100, year: 2019,
                                           skuType: 2, skuCaps: (1 << 9))),
                       "Slim N")
    }

    func testNilOutsideCSMEScope() {
        // Non-CSME variant → nil (family handled elsewhere or not at all).
        var nonCSME = Self.facts()
        nonCSME.variant = "CSTXE"
        XCTAssertNil(SKU.csme(nonCSME))
        // CSME 10 and older are not this decode's business.
        XCTAssertNil(SKU.csme(Self.facts(major: 10, minor: 0)))
        // No 0x0C and no 0x0F → nothing to name the SKU with.
        XCTAssertNil(SKU.csme(Self.facts(skuType: nil, skuCaps: nil, fwSku: nil)))
    }

    // MARK: - CSME 11

    /// The real CSME-11 dump: 0x0C says Corporate (SKU Type 0) and its SKU
    /// Platform field says Low Power, which is the whole answer — the console
    /// prints "Corporate LP".
    func testCSME11ReadsItsPlatformFromTheExtension() {
        let facts = Self.facts(major: 11, minor: 8, hotfix: 92, build: 4222,
                               year: 2022, month: 2, skuType: 0,
                               skuCaps: 0xFFFF_FFDF, skuPlatform: 1)
        XCTAssertEqual(SKU.csme(facts), "Corporate LP")

        var halo = facts
        halo.skuPlatform = 0
        XCTAssertEqual(SKU.csme(halo), "Corporate H")
    }

    /// The extension only speaks from 11.0.0.1205 on. Before that upstream
    /// reads the letter out of the Huffman-decompressed `kernel` module — a
    /// scan that is not ported — so such a firmware falls back to its database
    /// row, and says nothing at all without one.
    func testCSME11FallsBackToTheDatabaseRowOnOlderBuilds() {
        let row = "11.0.0.1180_COR_LP_C_NPDM_PRD_RGN_ABCD"
        let old = Self.facts(major: 11, minor: 0, hotfix: 0, build: 1180,
                             skuType: 0, skuPlatform: 1, databaseRow: row)
        XCTAssertEqual(SKU.csme(old), "Corporate LP",
                       "the platform comes from the row, not the extension")

        var unrecorded = old
        unrecorded.databaseRow = nil
        XCTAssertNil(SKU.csme(unrecorded))

        // 11.0.0.1205 is where the extension starts being read — and 7101 is
        // the one build past it that upstream excludes.
        var atTheCut = old
        atTheCut.build = 1205
        atTheCut.databaseRow = nil
        XCTAssertEqual(SKU.csme(atTheCut), "Corporate LP")
        var excluded = atTheCut
        excluded.build = 7101
        XCTAssertNil(SKU.csme(excluded))
    }

    /// A CSME 11 whose SKU Platform field carries something outside the two
    /// documented values is not guessed at.
    func testCSME11WithAnUnreadablePlatformSaysNothing() {
        XCTAssertNil(SKU.csme(Self.facts(major: 11, minor: 8, hotfix: 92,
                                         build: 4222, skuType: 0,
                                         skuPlatform: 3)))
    }
}
