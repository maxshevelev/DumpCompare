import XCTest
import Foundation
@testable import MEFirmware

final class FirmwareAnalysisModelTests: XCTestCase {
    func testCodableRoundTripPreservesFacts() throws {
        let model = FirmwareAnalysis(
            family: .csme,
            variant: "CSME",
            version: Version(major: 15, minor: 40, hotfix: 37, build: 3121),
            securityVersion: "3",
            release: .production,
            type: .region,
            sku: "5C",
            platform: "Consumer",
            manufactureDate: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 0x5000,
            databaseName: "15.40.37.3121_SVR_LP_C_SPI_PRD_EXTR_<sha256>",
            rsaSignatureValid: true,
            checksums: Checksums(sha256: "abcd", sha384: nil, crc32: 0x1234_5678),
            regions: [
                FPTRegion(id: 0, name: "FTUE", offset: 0x1000, size: 0x800, flags: 0x01)
            ],
            manifest: nil,
            codePartition: nil,
            issues: [Issue(id: 1, severity: .warning, message: "something odd")]
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(FirmwareAnalysis.self, from: data)

        XCTAssertEqual(decoded, model)
        XCTAssertEqual(decoded.id, "csme-CSME-15.40.37.3121")
        XCTAssertEqual(decoded.version.text, "15.40.37.3121")
        XCTAssertEqual(decoded.regions[0].name, "FTUE")
    }

    func testDecodingOmitsNewerOptionalFields() throws {
        // Additive-only contract: a payload from a *future* revision that added a
        // field must still decode against this revision (missing keys -> nil/[]).
        let payload = """
        {"family":"csme","variant":"CSME","version":{"major":15,"minor":40,
         "hotfix":37,"build":3121,"meMajor":5,"meMinor":2},
         "release":"production","type":"region","sku":"","platform":"",
         "sizeBytes":2048,"regions":[],"issues":[],
         "someFutureField":{"x":1}}
        """
        let decoded = try JSONDecoder().decode(
            FirmwareAnalysis.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.family, .csme)
        XCTAssertEqual(decoded.version.meMajor, 5)
        XCTAssertEqual(decoded.manufactureDate, nil)
        XCTAssertEqual(decoded.issues, [])
    }

    func testStringRawEnumsSerializeByName() throws {
        let values: [FirmwareFamily] = [.csme, .gsc, .unknown]
        let data = try JSONEncoder().encode(values)
        let strings = try JSONDecoder().decode([String].self, from: data)
        XCTAssertEqual(strings, ["csme", "gsc", "unknown"])
    }

    func testEngineModelRevisionBumpsWithAdditiveChanges() {
        XCTAssertEqual(EngineModelRevision.current, 3)
    }
}

final class MEADatabaseTests: XCTestCase {
    func testParsesRevisionMarker() {
        let db = MEADatabase.parse("*** Revision r378 (2026-09-01) ***\n15.40.37.3121_...\n")
        XCTAssertEqual(db.revision, 378)
    }

    func testNoRevisionYieldsNil() {
        XCTAssertNil(MEADatabase.parse("just some firmware lines").revision)
    }
}

final class AnalyzerTests: XCTestCase {
    /// A stub data source — tests never touch the network (async-api §Testing seam).
    private struct StubSource: MEADataSource {
        let databaseResult: Result<MEADatabase, MEADataError>

        func database() async throws -> MEADatabase {
            try databaseResult.get()
        }
    }

    func testAnalyzeReturnsFPTPartitionsAndSize() async throws {
        let region = FPTFixture.fptRegion(entries: [
            ("FTUE", 0x1000, 0x800, 0x01),
            ("rbe",  0x2000, 0x200, 0x00),
        ])
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0x4000)

        XCTAssertEqual(result.sizeBytes, region.count)
        XCTAssertEqual(result.regions.count, 2)
        XCTAssertEqual(result.regions[0].name, "FTUE")
        XCTAssertEqual(result.regions[0].offset, 0x4000 + 0x1000)  // baseOffset applied
        XCTAssertEqual(result.regions[1].offset, 0x4000 + 0x2000)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAnalyzeWithoutFPTNotesAbsence() async throws {
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .failure(.offline(underlying: "n/a"))))
        let result = try await analyzer.analyze(region: Data(repeating: 0xFF, count: 64))
        XCTAssertEqual(result.regions.count, 0)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues[0].severity, .note)
    }

    func testAnalyzePopulatesOperationalCodePartition() async throws {
        // A CPD-headed FTPR partition (two modules) whose manifest the analyzer
        // picks; the owning $CPD becomes codePartition. baseOffset shifts its
        // absolute offset. No FPT => only the structural note; identity is
        // irrelevant to codePartition (stage-1 facts).
        var region = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2", "rbe"])
        region.append(ManifestFixture.manifest())
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0x1000)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.name, "FTPR")
        XCTAssertEqual(cp.offset, 0x1000)             // baseOffset + $CPD base (0)
        XCTAssertEqual(cp.headerVersion, 1)
        XCTAssertEqual(cp.headerLength, 0x10)
        XCTAssertEqual(cp.entryCount, 2)
        XCTAssertEqual(cp.checksumValid, true)
        XCTAssertEqual(cp.modules.count, 2)
        XCTAssertEqual(cp.modules[0].name, "$MN2")
        XCTAssertEqual(cp.modules[0].id, 0)
        XCTAssertEqual(cp.modules[0].offset, 0)
        XCTAssertEqual(cp.modules[0].isHuffman, false)
        XCTAssertEqual(cp.modules[1].name, "rbe")
        XCTAssertEqual(result.manifest?.format, .r1)  // same region fed a manifest
    }

    func testAnalyzeLeavesCodePartitionNilWithoutOwningCPD() async throws {
        // An $FPT FTPR partition whose manifest has no owning $CPD: the manifest
        // summary is still reported, codePartition stays nil.
        let fpt = FPTFixture.fptRegion(entries: [
            ("FTPR", 0x1000, 0x2000, 0)
        ])
        var region = fpt
        region.append(Data(repeating: 0xFF, count: 0x1000 - fpt.count))  // manifest at 0x1000
        region.append(ManifestFixture.manifest())
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        XCTAssertNotNil(result.manifest)
        XCTAssertNil(result.codePartition)
    }
}
