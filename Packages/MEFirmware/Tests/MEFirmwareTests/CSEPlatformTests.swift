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

/// `VariantByModule` — `get_variant`'s module-name fallback, the step that
/// recognises the stitched independent firmware whose keys the database does
/// not list. The cases below are the oracle dumps' own: a CNP-era PMC (whose
/// key really is absent), the TGP/ADP ones, and the PCHC/PHY beside them.
final class VariantByModuleTests: XCTestCase {
    private func variant(_ modules: [String], major: Int, minor: Int = 0,
                         year: Int = 2021, meuMajor: Int? = 15,
                         meuMinor: Int? = 0) -> String? {
        VariantByModule.variant(moduleNames: modules, major: major, minor: minor,
                                year: year, meuMajor: meuMajor, meuMinor: meuMinor)
    }

    /// Every PMC carries a module called `PMCC000`; its own major says which
    /// platform's PMC it is.
    func testPMCPlatformsByMajor() {
        XCTAssertEqual(variant(["PMCC000"], major: 300), "PMCCNP")
        XCTAssertEqual(variant(["PMCC000"], major: 150), "PMCTGP")
        XCTAssertEqual(variant(["PMCC000"], major: 160), "PMCADP")
        XCTAssertEqual(variant(["PMCC000"], major: 140), "PMCCMP")
        // The CMP-V and JSP rules take the MEU minor as the tie-breaker.
        XCTAssertEqual(variant(["PMCC000"], major: 140, meuMinor: 5), "PMCCMPV")
        XCTAssertEqual(variant(["PMCC000"], major: 130, meuMinor: 50), "PMCJSP")
        XCTAssertEqual(variant(["PMCC000"], major: 130), "PMCICP")
        // An early low-major PMC is a CNP by its date.
        XCTAssertEqual(variant(["PMCC000"], major: 3, year: 2017), "PMCCNP")
        // Later than that, the date rule does not apply — and version 3.0
        // then falls through to the CSTXE tail below, as upstream's does.
        XCTAssertEqual(variant(["PMCC000"], major: 3, year: 2019), "CSTXE")
        XCTAssertNil(variant(["PMCC000"], major: 3, minor: 7, year: 2019))
        // A pre-MEU WTL PMC, where the manifest carries no MEU block at all.
        XCTAssertEqual(variant(["PMCC000"], major: 1, meuMajor: nil, meuMinor: nil),
                       "PMCWTL")
    }

    func testPCHCAndPHYByModuleAndVersion() {
        XCTAssertEqual(variant(["IntelRec"], major: 16), "PCHCADP")
        XCTAssertEqual(variant(["IntelRec"], major: 15, meuMinor: 0), "PCHCTGP")
        XCTAssertEqual(variant(["IntelRec"], major: 15, meuMinor: 40), "PCHCMCC")
        XCTAssertEqual(variant(["IntelRec"], major: 13, minor: 0), "PCHCICP")
        XCTAssertEqual(variant(["nphy"], major: 15, meuMajor: 15), "PHYNTGP")
        XCTAssertEqual(variant(["gen4_i"], major: 13, meuMajor: 16), "PHYNADP")
        XCTAssertEqual(variant(["SNPMULTI"], major: 13, meuMajor: 16), "PHYSADP")
    }

    /// The engine families the fallback also names, and the two version-only
    /// rules that close it.
    func testEngineFamiliesAndTheCSTXETail() {
        XCTAssertEqual(variant(["kernel", "fwupdate", "bup"], major: 15), "CSME")
        XCTAssertEqual(variant(["bup_rcv"], major: 5), "CSSPS")
        XCTAssertEqual(variant(["gfx_srv"], major: 1), "GSC")
        XCTAssertEqual(variant(["VBT"], major: 20), "OROMDG2")
        // Nothing recognised, but these two versions are a CSTXE.
        XCTAssertEqual(variant(["whatever"], major: 4, minor: 0), "CSTXE")
        XCTAssertNil(variant(["whatever"], major: 5, minor: 0))
        // No modules at all: this step has nothing to read.
        XCTAssertNil(variant([], major: 4, minor: 0))
    }

    /// The last module that matches decides, exactly as upstream's
    /// break-less loop leaves it.
    func testTheLastMatchingModuleDecides() {
        XCTAssertEqual(variant(["fwupdate", "PMCC000"], major: 300), "PMCCNP")
        XCTAssertEqual(variant(["PMCC000", "fwupdate"], major: 300), "CSME")
    }
}
