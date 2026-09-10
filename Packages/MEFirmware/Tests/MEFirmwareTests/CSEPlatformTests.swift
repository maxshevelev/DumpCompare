import XCTest
@testable import MEFirmware

/// `CSEPlatformNames` — row 22's Chipset Support for the CSE families: named
/// from the firmware's own version, and for CSME only when no chipset
/// initialisation table already says which chipset it initialises.
final class CSEPlatformTests: XCTestCase {
    private func name(_ family: FirmwareFamily, _ major: Int, _ minor: Int,
                      _ table: CSEPlatformNames.ChipsetInitTable = .absent) -> String? {
        CSEPlatformNames.name(family: family, major: major, minor: minor,
                              chipsetInitTable: table)
    }

    /// The CSME table, at the versions the oracles cover and the ones around
    /// them.
    func testCSMEPlatformsByVersion() {
        XCTAssertEqual(name(.csme, 11, 0), "SPT")
        XCTAssertEqual(name(.csme, 11, 8), "SPT/KBP")
        XCTAssertEqual(name(.csme, 11, 12), "BSF/GCF")
        XCTAssertEqual(name(.csme, 11, 22), "LBG")
        XCTAssertEqual(name(.csme, 12, 0), "CNP")
        XCTAssertEqual(name(.csme, 13, 30), "LKF")
        XCTAssertEqual(name(.csme, 14, 5), "CMP-V")
        XCTAssertEqual(name(.csme, 15, 0), "TGP")
        XCTAssertEqual(name(.csme, 15, 40), "MCC")
        XCTAssertEqual(name(.csme, 16, 1), "ADP/RPP")
        // A minor upstream has no name for says nothing.
        XCTAssertNil(name(.csme, 11, 3))
        XCTAssertNil(name(.csme, 16, 5))
    }

    /// The row belongs to the firmware whose chipset is otherwise unknown: an
    /// image whose initialisation table names one gets no Chipset Support row,
    /// and neither does one whose file system this engine cannot read — it
    /// cannot tell whether such a table is in there.
    func testTheInitialisationTableTakesTheRowInstead() {
        XCTAssertNil(name(.csme, 16, 1, .present))
        XCTAssertNil(name(.csme, 16, 1, .unknown))
        XCTAssertEqual(name(.csme, 16, 1, .absent), "ADP/RPP")
    }

    /// CSTXE names its three platforms whatever the file system holds.
    func testCSTXEPlatformsIgnoreTheTable() {
        XCTAssertEqual(name(.cstxe, 3, 0, .present), "APL")
        XCTAssertEqual(name(.cstxe, 3, 2, .present), "BXT")
        XCTAssertEqual(name(.cstxe, 4, 0, .present), "GLK")
        XCTAssertNil(name(.cstxe, 5, 0))
    }

    /// The families whose names are not ported say nothing rather than
    /// guessing — (CS)SPS picks its platform from a SKU-platform cell, and GSC
    /// from its own table.
    func testUnportedFamiliesNameNothing() {
        XCTAssertNil(name(.cssps, 5, 0))
        XCTAssertNil(name(.gsc, 1, 0))
        XCTAssertNil(name(.me, 7, 1))
    }
}
