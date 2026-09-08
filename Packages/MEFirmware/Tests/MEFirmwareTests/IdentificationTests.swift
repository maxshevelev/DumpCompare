import XCTest
import Foundation
@testable import MEFirmware

/// Reference constants (computed independently, see commit note): SHA-256 of
/// the default ManifestFixture key and signature byte patterns, and a second
/// key/signature pair for "not in database" cases.
enum FixtureHashes {
    static let key = "40AFF2E9D2D8922E47AFD4648E6967497158785FBD1DA870E7110266BF944880"
    static let sig = "CD6816B77F68D70001FC3EAA4D42BDD67CB5973B3151CC5292ECC02A3DAAC6AB"
    static let unknownKey = "CD1E95071E2F5A071154694AC11838B51731501608CCC6B8F8DC38D94CBC5872"
    static let unknownSig = "FDE27382A8C549406680FAF2B36D51520301B7C0816B783EF8C6E3F5D7E0B34D"
    static let preKey = "0EFA4E47B05819533ECCC4C09EE6B628F117C64ECD51BB1685EA90A52DE784B9"
}

/// A stub MEADataSource built from fixture MEA.dat text — tests never network.
private struct StubSource: MEADataSource {
    let databaseResult: Result<MEADatabase, MEADataError>
    func database() async throws -> MEADatabase { try databaseResult.get() }
}

/// MEA.dat fixture strings. Keyed off the reference hashes above.
enum FixtureDB {
    /// A production CSME entry whose key/signature are in the DB.
    static func csme(signature: String = FixtureHashes.sig,
                     preKeys: [String] = []) -> String {
        """
        *** ME Analyzer Engine Firmware Repository Database ***
        *** Revision r378 (2026-09-06 , 14:48) ***

        *** Converged Security Management Engine (CSME) ***
        15.40.37.3121_SVR_LP_C_SPI_PRD_EXTR_\(signature)

        *** RSA Public Keys ***
        RSAPKEY_CSME_\(FixtureHashes.key) (15.40 PRD)

        *** Structures ***
        rsa_pre_keys*BGN
        [
        \(preKeys.map { "\"\($0)\"" }.joined(separator: ",\n"))
        ]
        rsa_pre_keys*END
        """
    }

    /// A DB that carries no line for the fixture key (unknown firmware).
    static func unrelated() -> String {
        """
        *** ME Analyzer Engine Firmware Repository Database ***
        *** Revision r378 (2026-09-06 , 14:48) ***

        *** Management Engine (ME) ***
        9.5.65.3148_0A_M_PRD_EXTR_\(FixtureHashes.unknownSig)
        """
    }
}

final class IdentificationTests: XCTestCase {
    /// A region carrying a minimal FPT (so the "no $FPT" note stays quiet) plus
    /// the default R1 CSME manifest appended after it.
    private static func region(romBypass: Bool = false,
                               params: ManifestFixture.Params = ManifestFixture.Params()) -> Data {
        let entries: [(name: String, offset: UInt32, size: UInt32, flags: UInt32)] =
            romBypass ? [("ROMB", 0x10, 0x100, 0x01)]
                      : [("FTPR", 0x100, 0x400, 0x01)]
        var data = FPTFixture.fptRegion(entries: entries)
        data.append(ManifestFixture.manifest(params))
        return data
    }

    private func analyze(_ text: String, region: Data) async throws -> FirmwareAnalysis {
        let db = MEADatabase.parse(text)
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(db)))
        return try await analyzer.analyze(region: region)
    }

    // ——— Happy path ———

    func testIdentifiesCSMEFamilyVersionReleaseAndDBRow() async throws {
        let result = try await analyze(FixtureDB.csme(), region: Self.region())

        XCTAssertEqual(result.family, .csme)
        XCTAssertEqual(result.variant, "CSME")
        XCTAssertEqual(result.version.major, 15)
        XCTAssertEqual(result.version.minor, 40)
        XCTAssertEqual(result.version.hotfix, 37)
        XCTAssertEqual(result.version.build, 3121)
        XCTAssertEqual(result.version.meMajor, 15)   // MEU block surfaced
        XCTAssertEqual(result.version.meMinor, 40)
        XCTAssertEqual(result.securityVersion, "3")  // SVN
        XCTAssertEqual(result.release, .production)  // Debug flag 0, not a PRE key
        XCTAssertEqual(result.databaseName, "15.40.37.3121_SVR_LP_C_SPI_PRD_EXTR_\(FixtureHashes.sig)")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testIdentifiesWithBaseOffset() async throws {
        let db = MEADatabase.parse(FixtureDB.csme())
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(db)))
        let result = try await analyzer.analyze(region: Self.region(), baseOffset: 0x1000)
        XCTAssertEqual(result.family, .csme)
        XCTAssertEqual(result.regions[0].offset, 0x1000 + 0x100)
    }

    // ——— Release derivation ———

    func testPreProductionKeyCorrectsWrongProduction() async throws {
        // Debug flag is 0 (would say Production) but the key is a known
        // rsa_pre_keys entry → release_fix reclassifies to Pre-Production.
        let dbText = FixtureDB.csme(preKeys: [FixtureHashes.key])
        let result = try await analyze(dbText, region: Self.region())
        XCTAssertEqual(result.release, .preProduction)
    }

    func testDebugSignedFlagMeansPreProduction() async throws {
        var params = ManifestFixture.Params()
        params.flags = 0x8000_0001
        let result = try await analyze(FixtureDB.csme(), region: Self.region(params: params))
        XCTAssertEqual(result.release, .preProduction)
    }

    func testRomBypassPartitionMeansRomBypassRelease() async throws {
        let result = try await analyze(FixtureDB.csme(), region: Self.region(romBypass: true))
        XCTAssertEqual(result.release, .romBypass)
    }

    // ——— DB absence ———

    func testUnknownKeyYieldsUnknownFamilyAndNote() async throws {
        // A manifest whose key is not in the DB at all.
        var params = ManifestFixture.Params()
        params.key = Array(0..<0x100).map { UInt8((0x33 + $0) % 0x100) }
        params.signature = Array(0..<0x100).map { UInt8((0xCC - ($0 % 0x100)) & 0xFF) }
        let result = try await analyze(FixtureDB.unrelated(), region: Self.region(params: params))

        XCTAssertEqual(result.family, .unknown)
        XCTAssertEqual(result.variant, "")
        // Version is still a fact read from the manifest.
        XCTAssertEqual(result.version.major, 15)
        XCTAssertEqual(result.issues.map(\.id), [2])
    }

    func testRecognisedEngineNotInDBGetsNote() async throws {
        // Variant resolves (key in DB) but no firmware row carries its signature
        // hash — note_new_fw territory.
        let dbText = FixtureDB.csme(signature: FixtureHashes.unknownSig)
        let result = try await analyze(dbText, region: Self.region())

        XCTAssertEqual(result.family, .csme)
        XCTAssertNil(result.databaseName)
        XCTAssertEqual(result.issues.map(\.id), [3])
    }

    // ——— Shared pre-key override (pure classification) ———

    func testSharedPreKeyOverrideByMajor() {
        let shared = Identifier.sharedMEKeyHash
        XCTAssertEqual(Identifier.preKeyOverride(keyHash: shared, major: 7), "ME")
        XCTAssertEqual(Identifier.preKeyOverride(keyHash: shared, major: 10), "ME")
        XCTAssertEqual(Identifier.preKeyOverride(keyHash: shared, major: 1), "TXE")
        XCTAssertEqual(Identifier.preKeyOverride(keyHash: shared, major: 11), nil) // CSME
        XCTAssertEqual(Identifier.preKeyOverride(keyHash: "other", major: 7), nil)
    }
}
