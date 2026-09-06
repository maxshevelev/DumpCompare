import XCTest
@testable import FITTool

/// The list of microcode that can be added, read from the file names in
/// `github.com/platomav/CPUMicrocodes`.
final class MicrocodeCatalogueTests: XCTestCase {
    /// A slice of GitHub's recursive tree listing, with the shapes that matter:
    /// a modern Intel file, an old one, the licence, a directory, and AMD —
    /// which has no platform field and cannot go in a FIT at all.
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
       "type": "blob", "size": 3200}
    ], "truncated": false}
    """.utf8)

    private func entries() throws -> [MicrocodeCatalogueEntry] {
        try MicrocodeCatalogue.entries(fromTree: tree)
    }

    /// Everything shown in the form comes out of the name, which is what makes
    /// a thousand files searchable without downloading one of them.
    func testAnIntelNameIsReadFieldByField() throws {
        let entry = try XCTUnwrap(entries().first { $0.path.contains("906EB_plat02") })

        XCTAssertEqual(entry.cpuid, 0x906EB)
        XCTAssertEqual(entry.cpuidText, "906EB")
        XCTAssertEqual(entry.platformID, 0x02)
        XCTAssertEqual(entry.revision, 0x7C)
        XCTAssertEqual(entry.revisionText, "7C")
        XCTAssertEqual(entry.date, "2017-12-03")
        XCTAssertTrue(entry.isProduction)
        XCTAssertEqual(entry.size, 98304)
        XCTAssertEqual(entry.fileName, "cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.bin")
    }

    /// A pre-release is worth telling apart from a production one before it
    /// goes into somebody's board.
    func testAPreReleaseIsMarked() throws {
        let entry = try XCTUnwrap(entries().first { $0.path.contains("PRE") })

        XCTAssertFalse(entry.isProduction)
        XCTAssertEqual(entry.platformID, 0x22)
    }

    /// AMD and VIA microcode is in the same repository and cannot go into an
    /// Intel FIT (§7.1), so it is not offered — and neither is the licence.
    func testOnlyIntelMicrocodeIsListed() throws {
        let paths = try entries().map(\.path)

        XCTAssertFalse(paths.contains { $0.hasPrefix("AMD/") })
        XCTAssertFalse(paths.contains { $0.hasSuffix("LICENSE") })
        XCTAssertEqual(paths.count, 3)
    }

    func testTheListIsOrderedByCpuidThenRevision() throws {
        XCTAssertEqual(try entries().map(\.cpuidText), ["611", "906EB", "906EB"])
        XCTAssertEqual(try entries().map(\.revisionText), ["B27", "7C", "F0"])
    }

    func testANameThatIsNotAMicrocodeFileIsSkipped() {
        XCTAssertNil(MicrocodeCatalogue.entry(at: "Intel/README.md", size: 10))
        XCTAssertNil(MicrocodeCatalogue.entry(at: "Intel/notes.bin", size: 10))
        XCTAssertNil(MicrocodeCatalogue.entry(at: "Intel/cpu906EB.bin", size: 10))
        // Named like microcode, and not microcode.
        XCTAssertNil(MicrocodeCatalogue.entry(
            at: "Intel/cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.txt", size: 10
        ))
    }

    // MARK: - Narrowing it down

    func testSearchingMatchesTheCpuidAsItIsWritten() throws {
        let found = MicrocodeCatalogue.filter(try entries(), search: "906")

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(MicrocodeCatalogue.filter(try entries(), search: "  906eb ").count == 2)
        XCTAssertTrue(MicrocodeCatalogue.filter(try entries(), search: "zzz").isEmpty)
    }

    func testSearchingAlsoMatchesARevisionOrAFileName() throws {
        XCTAssertEqual(MicrocodeCatalogue.filter(try entries(), search: "B27").count, 1)
        XCTAssertEqual(MicrocodeCatalogue.filter(try entries(), search: "1996").count, 1)
    }

    func testFilteringByPlatform() throws {
        XCTAssertEqual(MicrocodeCatalogue.filter(try entries(), platformID: 0x22).count, 1)
        XCTAssertEqual(MicrocodeCatalogue.platformIDs(in: try entries()), [0x00, 0x02, 0x22])
    }

    /// The useful default: a dump is for one board, and what is worth adding to
    /// it is almost always a newer revision of a CPUID its table already names.
    func testFilteringToTheCpuidsAlreadyInTheImage() throws {
        let found = MicrocodeCatalogue.filter(try entries(), cpuidsInTheImage: [0x906EB])

        XCTAssertEqual(found.map(\.cpuidText), ["906EB", "906EB"])
        XCTAssertTrue(MicrocodeCatalogue.filter(try entries(), cpuidsInTheImage: []).isEmpty)
    }

    func testTheFiltersCombine() throws {
        let found = MicrocodeCatalogue.filter(
            try entries(), search: "906", platformID: 0x02, cpuidsInTheImage: [0x906EB]
        )

        XCTAssertEqual(found.map(\.revisionText), ["7C"])
    }
}
