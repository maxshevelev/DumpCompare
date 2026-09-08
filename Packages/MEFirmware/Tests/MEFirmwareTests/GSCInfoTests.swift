import XCTest
import Foundation
@testable import MEFirmware

/// Builds a synthetic GSC "INFO" $FPT partition payload — a u32 revision then a
/// `GSC_Info_FWI` image header (0x20) and `GSC_Info_IUP` rows (0x10 each).
/// Field offsets mirror the ctypes structs (MEA.py 358/410) so the decoder and
/// fixture agree byte-for-byte. No real GSC dump exists among the engine's
/// oracles — this is the fixture-only row-79 increment.
enum GSCInfoFixture {
    struct Params {
        var revision: UInt32 = 1
        var project: String = "GSCF"
        var hotfix: UInt16 = 0
        var build: UInt16 = 17
        var gscMajor: UInt16 = 5
        var gscMinor: UInt16 = 1
        var gscHotfix: UInt16 = 0
        var gscBuild: UInt16 = 2049
        var flags: UInt16 = 0x0003
        var fwType: UInt8 = 0x02
        var fwSku: UInt8 = 0x00
        var arbSvn: UInt32 = 0x0B
        var tcbSvn: UInt32 = 3
        var vcn: UInt32 = 4
        var iupNames: [String] = ["BP1", "BP2"]
    }

    static func setUInt16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }

    static func setUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data[offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// A standalone INFO payload (no $FPT): revision u32, then the image header
    /// at `4 + 0x00`, then one 0x10 IUP row per name.
    static func payload(_ params: Params = Params()) -> Data {
        let iupCount = params.iupNames.count
        var data = Data(repeating: 0, count: 4 + 0x20 + iupCount * 0x10)
        setUInt32(params.revision, in: &data, at: 0x00)          // revision

        let fwi = 4
        for (i, byte) in params.project.utf8.prefix(4).enumerated() {
            data[fwi + i] = byte
        }
        setUInt16(params.hotfix, in: &data, at: fwi + 0x04)
        setUInt16(params.build, in: &data, at: fwi + 0x06)
        setUInt16(params.gscMajor, in: &data, at: fwi + 0x08)
        setUInt16(params.gscMinor, in: &data, at: fwi + 0x0A)
        setUInt16(params.gscHotfix, in: &data, at: fwi + 0x0C)
        setUInt16(params.gscBuild, in: &data, at: fwi + 0x0E)
        setUInt16(params.flags, in: &data, at: fwi + 0x10)
        data[fwi + 0x12] = params.fwType
        data[fwi + 0x13] = params.fwSku
        setUInt32(params.arbSvn, in: &data, at: fwi + 0x14)
        setUInt32(params.tcbSvn, in: &data, at: fwi + 0x18)
        setUInt32(params.vcn, in: &data, at: fwi + 0x1C)

        for (idx, name) in params.iupNames.enumerated() {
            let row = fwi + 0x20 + idx * 0x10
            for (i, byte) in name.utf8.prefix(4).enumerated() {
                data[row + i] = byte
            }
            // flags 0x0004 / reserved 0x0000 / svn / vcn per row
            setUInt16(0x0004, in: &data, at: row + 0x04)
            setUInt16(0x0000, in: &data, at: row + 0x06)
            setUInt32(UInt32(idx + 1), in: &data, at: row + 0x08)
            setUInt32(UInt32(idx + 10), in: &data, at: row + 0x0C)
        }
        return data
    }
}

final class GSCInfoDecodeTests: XCTestCase {
    func testDecodesImageHeaderAndIUPRows() throws {
        let payload = GSCInfoFixture.payload()
        let info = try XCTUnwrap(GSCInfoParser.decode(in: payload, offset: 0,
                                                      size: payload.count))

        XCTAssertEqual(info.revision, 1)
        XCTAssertTrue(info.revisionValid)
        XCTAssertEqual(info.offset, 0)
        XCTAssertEqual(info.image.project, "GSCF")
        XCTAssertEqual(info.image.hotfix, 0)
        XCTAssertEqual(info.image.build, 17)
        XCTAssertEqual(info.image.gscMajor, 5)
        XCTAssertEqual(info.image.gscMinor, 1)
        XCTAssertEqual(info.image.gscHotfix, 0)
        XCTAssertEqual(info.image.gscBuild, 2049)
        XCTAssertEqual(info.image.flags, 0x0003)
        XCTAssertEqual(info.image.fwType, 0x02)
        XCTAssertEqual(info.image.fwSku, 0x00)
        XCTAssertEqual(info.image.arbSvn, 0x0B)
        XCTAssertEqual(info.image.tcbSvn, 3)
        XCTAssertEqual(info.image.vcn, 4)
        XCTAssertEqual(info.image.versionText, "5.1.0.2049")

        XCTAssertEqual(info.iupPartitions.count, 2)
        XCTAssertEqual(info.iupPartitions[0].name, "BP1")
        XCTAssertEqual(info.iupPartitions[0].flags, 0x0004)
        XCTAssertEqual(info.iupPartitions[0].svn, 1)
        XCTAssertEqual(info.iupPartitions[0].vcn, 10)
        XCTAssertEqual(info.iupPartitions[1].name, "BP2")
        XCTAssertEqual(info.iupPartitions[1].svn, 2)
    }

    func testVersionTextNAWhenGSCMajorZero() throws {
        var params = GSCInfoFixture.Params()
        params.gscMajor = 0
        let payload = GSCInfoFixture.payload(params)
        let info = try XCTUnwrap(GSCInfoParser.decode(in: payload, offset: 0,
                                                      size: payload.count))
        XCTAssertEqual(info.image.versionText, "N/A")
    }

    func testNonOneRevisionFlaggedButStillDecoded() throws {
        // Upstream prints "Unknown revision" but decodes anyway; the decoder
        // keeps the revision so the analyzer can raise an Issue.
        var params = GSCInfoFixture.Params()
        params.revision = 2
        let payload = GSCInfoFixture.payload(params)
        let info = try XCTUnwrap(GSCInfoParser.decode(in: payload, offset: 0,
                                                      size: payload.count))
        XCTAssertEqual(info.revision, 2)
        XCTAssertFalse(info.revisionValid)
        XCTAssertEqual(info.iupPartitions.count, 2)   // decode continued
    }

    func testBaseOffsetShiftsReportedAnchor() throws {
        let payload = GSCInfoFixture.payload()
        let info = try XCTUnwrap(GSCInfoParser.decode(in: payload, offset: 0,
                                                      size: payload.count,
                                                      baseOffset: 0x1000))
        XCTAssertEqual(info.offset, 0x1000)
    }

    func testDecodeWithinLargerRegionAtOffset() throws {
        // The partition sits 0x40 into a larger region (as after an $FPT header).
        let payload = GSCInfoFixture.payload()
        var region = Data(repeating: 0xAA, count: 0x40)
        region.append(payload)
        let info = try XCTUnwrap(GSCInfoParser.decode(in: region, offset: 0x40,
                                                      size: payload.count,
                                                      baseOffset: 0x1000))
        XCTAssertEqual(info.offset, 0x1000 + 0x40)
        XCTAssertEqual(info.image.project, "GSCF")
        XCTAssertEqual(info.iupPartitions.count, 2)
    }

    func testTooShortOrOutOfBoundsYieldsNil() {
        XCTAssertNil(GSCInfoParser.decode(in: Data(repeating: 0, count: 4 + 0x10),
                                          offset: 0, size: 4 + 0x10))
        XCTAssertNil(GSCInfoParser.decode(in: Data(repeating: 0, count: 0x200),
                                          offset: 0x200, size: 0x200))  // starts at the end
        // A partition starting before the end but whose revision + image header
        // would overrun the region also yields nil.
        XCTAssertNil(GSCInfoParser.decode(in: Data(repeating: 0, count: 0x200),
                                          offset: 0x1F0, size: 0x200))
    }
}

final class GSCInfoAnalyzerTests: XCTestCase {
    private struct StubSource: MEADataSource {
        let databaseResult: Result<MEADatabase, MEADataError>
        func database() async throws -> MEADatabase {
            try databaseResult.get()
        }
    }

    /// A region whose $FPT declares an "INFO" partition with the payload placed
    /// at its reported offset.
    private func region(infoPayload: Data, partitionOffset: UInt32 = 0x1000) -> Data {
        var region = FPTFixture.fptRegion(anchor: 0, entries: [
            ("INFO", partitionOffset, UInt32(infoPayload.count), 0)
        ])
        let gap = Int(partitionOffset) - region.count
        precondition(gap >= 0)
        region.append(Data(repeating: 0xFF, count: gap))
        region.append(infoPayload)
        return region
    }

    func testAnalyzeSurfacesGSCInfoFromINFORegion() async throws {
        let analyzer = MEFirmwareAnalyzer(
            data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))
        // No manifest: the analyzer returns the structural facts (regions +
        // gscInfo) offline; the INFO partition is a pure stage-1 decode.
        let result = try await analyzer.analyze(
            region: region(infoPayload: GSCInfoFixture.payload()),
            baseOffset: 0)

        XCTAssertEqual(result.regions.map(\.name), ["INFO"])
        let info = try XCTUnwrap(result.gscInfo)
        XCTAssertEqual(info.revisionValid, true)
        XCTAssertEqual(info.image.project, "GSCF")
        XCTAssertEqual(info.iupPartitions.count, 2)
        XCTAssertEqual(info.offset, 0x1000)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testAnalyzeWarnsOnUnknownRevision() async throws {
        var params = GSCInfoFixture.Params()
        params.revision = 7
        let analyzer = MEFirmwareAnalyzer(
            data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(
            region: region(infoPayload: GSCInfoFixture.payload(params)),
            baseOffset: 0)

        let info = try XCTUnwrap(result.gscInfo)
        XCTAssertFalse(info.revisionValid)
        XCTAssertTrue(result.issues.contains { $0.id == 12 && $0.severity == .warning
            && $0.message.contains("revision 7") })
    }

    func testAnalyzeLeavesGSCInfoNilWithoutINFORegion() async throws {
        var region = FPTFixture.fptRegion(anchor: 0, entries: [
            ("FTPR", 0x1000, 0x100, 0)
        ])
        region.append(Data(repeating: 0xFF, count: 0x100))
        let analyzer = MEFirmwareAnalyzer(
            data: StubSource(databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)
        XCTAssertNil(result.gscInfo)
    }
}
