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
            mfsVolume: nil,
            cseLayoutTable: CSELayoutTable(
                offset: 0x1000, version: 0x17, redundancy: true, checksumValid: true,
                partitions: [
                    CSELayoutPartition(id: 0, name: "Data", offset: 0x1F1000, size: 0x88000, empty: false),
                    CSELayoutPartition(id: 1, name: "Boot 1", offset: 0x3000, size: 0x1EE000, empty: false),
                ]),
            bootPartitions: [
                BPDT(offset: 0x3000, partitionName: "Boot 1", version: 2, redundancy: true,
                     checksumValid: true,
                     entries: [
                        BPDTPartition(id: 0, name: "RBEP", type: 1, offset: 0x4000, size: 0x18000, empty: false),
                        BPDTPartition(id: 1, name: "FTPR", type: 2, offset: 0x59000, size: 0x125000, empty: false),
                     ]),
            ],
            issues: [Issue(id: 1, severity: .warning, message: "something odd")]
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(FirmwareAnalysis.self, from: data)

        XCTAssertEqual(decoded, model)
        XCTAssertEqual(decoded.id, "csme-CSME-15.40.37.3121")
        XCTAssertEqual(decoded.version.text, "15.40.37.3121")
        XCTAssertEqual(decoded.regions[0].name, "FTUE")
        XCTAssertEqual(decoded.cseLayoutTable?.offset, 0x1000)
        XCTAssertEqual(decoded.cseLayoutTable?.partitions.count, 2)
        XCTAssertEqual(decoded.cseLayoutTable?.partitions[0].name, "Data")
        XCTAssertEqual(decoded.bootPartitions?.count, 1)
        XCTAssertEqual(decoded.bootPartitions?[0].offset, 0x3000)
        XCTAssertEqual(decoded.bootPartitions?[0].version, 2)
        XCTAssertEqual(decoded.bootPartitions?[0].entries[0].name, "RBEP")
        XCTAssertEqual(decoded.bootPartitions?[0].entries[1].offset, 0x59000)
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
        XCTAssertEqual(EngineModelRevision.current, 8)
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

    func testAnalyzeValidatesR2CodePartitionChecksum() async throws {
        // R2 $CPD (CRC-32 at +0x10). CPDFixture now stores a real CRC over
        // header+entries with the field zeroed, so the analyzer reports it valid.
        var region = CPDFixture.make(name: "FTPR", headerVersion: 2,
                                     moduleNames: ["$MN2", "rbe"])
        region.append(ManifestFixture.manifest())
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.headerVersion, 2)
        XCTAssertEqual(cp.checksumValid, true)     // R2 CRC-32 now validated
        // A valid directory adds no integrity warning (the no-$FPT note is fine).
        XCTAssertTrue(result.issues.allSatisfy { $0.severity != .warning })
        XCTAssertFalse(result.issues.contains { $0.message.contains("INVALID") })
    }

    func testAnalyzeWarnsOnInvalidChecksumAndOverrun() async throws {
        var region = CPDFixture.make(name: "FTPR", headerVersion: 2,
                                     moduleNames: ["$MN2", "rbe"])
        region[0x0C] ^= 0xFF                       // corrupt a PartitionName byte → CRC fails
        region.append(Data(repeating: 0, count: 0x18))  // empty slot right after the directory
        region.append(ManifestFixture.manifest())  // manifest after the slot → overrun probe fires
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.checksumValid, false)
        let severities = result.issues.map(\.severity)
        XCTAssertTrue(severities.contains(.warning))
        XCTAssertTrue(result.issues.contains { $0.message.contains("INVALID") })
        XCTAssertTrue(result.issues.contains { $0.message.contains("empty trailing module") })
    }

    func testAnalyzeDecodesManifestModuleExtensionChain() async throws {
        // A self-consistent FTPR region: a one-module $CPD whose single entry
        // (the manifest) is placed right after the directory, sized to cover the
        // manifest *and* an extension chain. The default manifest (major 15,
        // 2048-bit key) selects the csme15 header family, so 0x00/0x16 decode as
        // _R2 and 0x02 stays base. baseOffset shifts the chain's absolute offsets.
        let chain = ExtFixture.concat([
            ExtFixture.systemInfo(r2: true),
            ExtFixture.featurePermissions(moduleCount: 6, rowCount: 4),
            ExtFixture.partitionInfo(tag: 0x16, r2: true),
        ])
        let manifest = ManifestFixture.manifest()              // 0x284 bytes
        let manifestBase = 0x10 + 1 * 0x18                     // $CPD R1 header + one entry
        let moduleSize = manifest.count + chain.count          // manifest module spans both
        var region = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2"],
                                     moduleLayout: [(offset: UInt32(manifestBase),
                                                     size: UInt32(moduleSize))])
        XCTAssertEqual(region.count, manifestBase)
        region.append(manifest)
        region.append(chain)
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0x1000)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.modules[0].offset, manifestBase)
        let exts = try XCTUnwrap(cp.extensions)
        XCTAssertEqual(exts.map(\.tag), [0x00, 0x02, 0x16])
        XCTAssertEqual(exts.map(\.id), [0, 1, 2])
        // Chain begins at manifestBase + headerLength×4 = manifestBase + 0x284.
        XCTAssertEqual(exts[0].offset, 0x1000 + manifestBase + manifest.count)
        XCTAssertEqual(exts[0].systemInfo?.imageHash.count, 96)   // csme15 _R2 → SHA-384
        XCTAssertEqual(exts[0].systemInfo?.minUMASize, 0x1122_3344)
        XCTAssertEqual(exts[1].featurePermissions?.moduleCount, 6)
        XCTAssertEqual(exts[1].size, 0x1C)                        // header + 4 rows
        XCTAssertEqual(exts[2].partitionInfo?.partitionName, "FTPR")
        XCTAssertEqual(exts[2].partitionInfo?.hash.count, 96)     // 0x16 _R2
        XCTAssertNil(exts[2].partitionInfo?.vcn)                  // 0x16 has no VCN
    }

    func testAnalyzeDecodesMetModuleMetadata() async throws {
        // A two-module FTPR region: the manifest `.man` module plus a `kernel.met`
        // companion placed after it. The default manifest (major 15) selects the
        // csme15 family, so the .met's leading 0x0A decodes as _R2 (SHA-384). The
        // manifest module's row repeats CodePartition.extensions.
        let manChain = ExtFixture.concat([
            ExtFixture.systemInfo(r2: true),
            ExtFixture.featurePermissions(moduleCount: 4, rowCount: 2),
        ])
        let manifest = ManifestFixture.manifest()
        let manifestBase = 0x10 + 2 * 0x18                    // R1 $CPD + two entries
        let manSpan = manifest.count + manChain.count         // $MN2 module covers both
        let metBody = ExtFixture.concat([
            ExtFixture.moduleAttributes(r2: true),
            ExtFixture.block(tag: 0x09, headerLen: 0x0C, tail: 0x18),  // special-file producer
        ])
        let metBase = manifestBase + manSpan
        var region = CPDFixture.make(name: "FTPR",
                                     moduleNames: ["$MN2", "kernel.met"],
                                     moduleLayout: [
                                        (offset: UInt32(manifestBase), size: UInt32(manSpan)),
                                        (offset: UInt32(metBase), size: UInt32(metBody.count)),
                                     ])
        region.append(manifest)
        region.append(manChain)
        region.append(metBody)
        let analyzer = MEFirmwareAnalyzer(data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0x1000)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.modules.count, 2)

        // Manifest module row carries the same .man chain as CodePartition.extensions.
        XCTAssertEqual(cp.modules[0].name, "$MN2")
        XCTAssertEqual(cp.modules[0].offset, manifestBase)
        XCTAssertEqual(cp.modules[0].extensions, cp.extensions)
        XCTAssertEqual(cp.modules[0].extensions?.map(\.tag), [0x00, 0x02])

        // The .met row decoded its own body as a chain from its content base.
        let met = cp.modules[1]
        XCTAssertEqual(met.name, "kernel.met")
        XCTAssertEqual(met.isHuffman, false)
        XCTAssertEqual(met.size, metBody.count)
        let exts = try XCTUnwrap(met.extensions)
        XCTAssertEqual(exts.map(\.tag), [0x0A, 0x09])
        XCTAssertEqual(exts[0].offset, 0x1000 + metBase)          // absolute, chain at body base
        let attrs = try XCTUnwrap(exts[0].moduleAttributes)
        XCTAssertEqual(attrs.compression, 1)                       // Huffman
        XCTAssertEqual(attrs.encryption, 0)
        XCTAssertEqual(attrs.uncompressedSize, 0x15000)
        XCTAssertEqual(attrs.compressedSize, 0xDDD4)
        XCTAssertEqual(attrs.deviceID, 2)
        XCTAssertEqual(attrs.vendorID, 0x8086)
        XCTAssertEqual(attrs.moduleHash.count, 96)                 // csme15 → SHA-384
        XCTAssertNil(exts[1].moduleAttributes)                     // 0x09 row-tag: envelope
        XCTAssertEqual(exts[1].size, 0x24)
        XCTAssertEqual(cp.checksumValid, true)                     // directory stayed intact
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
