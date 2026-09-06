import XCTest
@testable import FITTool
import UEFIFormat

/// The list of microcode that can be browsed and added, read from the file
/// names in `github.com/platomav/CPUMicrocodes`.
final class MicrocodeCatalogueTests: XCTestCase {
    /// A slice of GitHub's recursive tree listing, with one of every shape the
    /// four vendors write: they agree about almost nothing.
    private let tree = Data("""
    {"sha": "abc", "tree": [
      {"path": "Intel", "type": "tree"},
      {"path": "Intel/LICENSE", "type": "blob", "size": 1642},
      {"path": "Intel/cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.bin",
       "type": "blob", "size": 98304},
      {"path": "Intel/cpu00611_plat00_ver00000B27_1996-12-18_PRD_05793E46.bin",
       "type": "blob", "size": 2048},
      {"path": "Intel/cpu906EB_plat22_ver000000F0_2021-11-12_PRE_1B2C3D4E.bin",
       "type": "blob", "size": 102400},
      {"path": "AMD/cpu00800F11_ver08001129_2017-07-14_4F426450.bin",
       "type": "blob", "size": 3200},
      {"path": "VIA/cpu10690_ver00000001_sig[BJ_10690.020]_2017-01-09_A8B24DC2.bin",
       "type": "blob", "size": 2048},
      {"path": "Freescale/soc8360_rev2.1_sig[Soft-UART]_3725F40B.bin",
       "type": "blob", "size": 1024},
      {"path": "README.md", "type": "blob", "size": 4096}
    ], "truncated": false}
    """.utf8)

    private func entries() throws -> [MicrocodeCatalogueEntry] {
        try MicrocodeCatalogue.entries(fromTree: tree)
    }

    private func entry(_ contains: String) throws -> MicrocodeCatalogueEntry {
        try XCTUnwrap(entries().first { $0.path.contains(contains) })
    }

    /// Everything shown in the form comes out of the name, which is what makes
    /// thousands of files searchable without downloading one of them.
    func testAnIntelNameIsReadFieldByField() throws {
        let entry = try entry("906EB_plat02")

        XCTAssertEqual(entry.vendor, .intel)
        XCTAssertEqual(entry.cpuid, 0x906EB)
        XCTAssertEqual(entry.cpuidText, "906EB")
        XCTAssertEqual(entry.platformID, 0x02)
        XCTAssertEqual(entry.platformText, "02")   // as the file name writes it
        XCTAssertEqual(entry.revisionText, "7C")
        XCTAssertEqual(entry.date, "2017-12-03")
        XCTAssertTrue(entry.isProduction)
        XCTAssertEqual(entry.size, 98304)
    }

    /// Only Intel has a platform id, and its absence is not a defect in the
    /// other three.
    func testAnAmdNameHasNoPlatform() throws {
        let entry = try entry("AMD/")

        XCTAssertEqual(entry.vendor, .amd)
        XCTAssertEqual(entry.cpuidText, "800F11")
        XCTAssertNil(entry.platformID)
        XCTAssertEqual(entry.platformText, "")
        XCTAssertEqual(entry.revisionText, "8001129")
        XCTAssertEqual(entry.date, "2017-07-14")
    }

    /// VIA puts a signature field in the middle of the name, which is neither a
    /// date nor a version and must not be read as either.
    func testAViaNameIsReadPastItsSignatureField() throws {
        let entry = try entry("VIA/")

        XCTAssertEqual(entry.vendor, .via)
        XCTAssertEqual(entry.cpuidText, "10690")
        XCTAssertEqual(entry.revisionText, "1")
        XCTAssertEqual(entry.date, "2017-01-09")
    }

    /// Freescale names a system-on-chip where the others name a CPUID, and its
    /// revision is `2.1` rather than a hexadecimal number. Neither fits the
    /// fields the others use, and neither is dropped.
    func testAFreescaleNameHasNoCpuidAndNoHexRevision() throws {
        let entry = try entry("Freescale/")

        XCTAssertEqual(entry.vendor, .freescale)
        XCTAssertNil(entry.cpuid)
        XCTAssertEqual(entry.cpuidText, "8360")
        XCTAssertEqual(entry.revisionText, "2.1")
        XCTAssertEqual(entry.date, "")
    }

    /// A pre-release is worth telling apart from a production one before it
    /// goes into somebody's board.
    func testAPreReleaseIsMarked() throws {
        XCTAssertFalse(try entry("PRE").isProduction)
        XCTAssertTrue(try entry("906EB_plat02").isProduction)
    }

    func testWhatIsNotAMicrocodeFileIsSkipped() throws {
        XCTAssertFalse(try entries().contains { $0.path.hasSuffix("LICENSE") })
        XCTAssertFalse(try entries().contains { $0.path == "README.md" })
        XCTAssertEqual(try entries().count, 6)

        XCTAssertNil(MicrocodeCatalogue.entry(at: "Intel/README.md", size: 10))
        XCTAssertNil(MicrocodeCatalogue.entry(at: "Intel/notes.bin", size: 10))
        // A name with no revision field in it is not one of these.
        XCTAssertNil(MicrocodeCatalogue.entry(
            at: "Intel/cpu906EB_plat02_2017-12-03_PRD_5046D998.bin", size: 10
        ))
        // Named like microcode, in no vendor's directory.
        XCTAssertNil(MicrocodeCatalogue.entry(
            at: "cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.bin", size: 10
        ))
    }

    // MARK: - Narrowing it down

    /// Only Intel is ever offered — a FIT names no other kind — but all four
    /// are read, because the listing is of the whole repository and telling
    /// them apart is what keeps AMD's names from being read as Intel's.
    func testTheVendorDecidesWhatIsListed() throws {
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .intel).map(\.cpuidText),
            ["611", "906EB", "906EB"]
        )
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .freescale).map(\.cpuidText),
            ["8360"]
        )
        XCTAssertEqual(
            MicrocodeCatalogue.counts(in: try entries()),
            [.intel: 3, .amd: 1, .via: 1, .freescale: 1]
        )
    }

    /// The list of one vendor is long, and the search is how a CPUID is found
    /// in it.
    func testSearchingMatchesTheCpuidAsItIsWritten() throws {
        let found = MicrocodeCatalogue.filter(try entries(), vendor: .intel, search: "906")

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .intel, search: "  906eb ").count, 2
        )
        XCTAssertTrue(MicrocodeCatalogue.filter(try entries(), vendor: .intel, search: "zzz").isEmpty)
    }

    func testSearchingAlsoMatchesARevisionOrAFileName() throws {
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .intel, search: "B27").count, 1
        )
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .intel, search: "1996").count, 1
        )
    }

    /// The narrowing a bench asks for by hand: a dump is for one board.
    func testFilteringToTheCpuidsAlreadyInTheImage() throws {
        let found = MicrocodeCatalogue.filter(
            try entries(), vendor: .intel, cpuidsInTheImage: [0x906EB]
        )

        XCTAssertEqual(found.map(\.cpuidText), ["906EB", "906EB"])
        XCTAssertTrue(MicrocodeCatalogue.filter(
            try entries(), vendor: .intel, cpuidsInTheImage: []
        ).isEmpty)
        // Freescale has no CPUID at all, so nothing of it survives that filter.
        XCTAssertTrue(MicrocodeCatalogue.filter(
            try entries(), vendor: .freescale, cpuidsInTheImage: [0x8360]
        ).isEmpty)
    }

    func testTheFiltersCombine() throws {
        let found = MicrocodeCatalogue.filter(
            try entries(), vendor: .intel, search: "906", cpuidsInTheImage: [0x906EB]
        )

        XCTAssertEqual(found.map(\.revisionText), ["7C", "F0"])
    }

    /// Shortest first, so a five-digit Intel CPUID does not sort in among AMD's
    /// longer ones, and the revisions of one processor stay together — an order
    /// of the *processors*, which is what a person scrolls this list looking
    /// for, rather than of the paths the files happen to sit at.
    func testTheListIsOrderedByCpuidThenRevision() throws {
        XCTAssertEqual(
            try entries().map(\.cpuidText),
            ["611", "8360", "10690", "906EB", "906EB", "800F11"]
        )
        XCTAssertEqual(
            MicrocodeCatalogue.filter(try entries(), vendor: .intel).map(\.revisionText),
            ["B27", "7C", "F0"]
        )
    }
}
