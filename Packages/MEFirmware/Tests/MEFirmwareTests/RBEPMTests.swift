import XCTest
import Foundation
@testable import MEFirmware

/// Builds synthetic FTPR `pm` / RBEP `rbe` module bodies whose contiguous
/// `RBE_PM_Metadata` rows satisfy `get_rbe_pm_met` (MEA.py 9711) — three
/// consecutive `VEN_ID` 0x8086 words (`86 80`) spaced `stride` bytes apart.
/// Each row is `stride` bytes: `Unknown0`/`DEV_ID`/`VEN_ID`/`SizeUncomp`/
/// `SizeComp`, the six extended fields for r1/r3, and the hash at the layout's
/// offset (0x28 r1/r3, 0x10 r2/r4). Field offsets mirror the structs (MEA.py
/// 5161–5295) so decoder and fixture agree byte-for-byte.
enum RBEPMFixture {
    struct Spec {
        let stride: Int
        let extended: Bool
        let hashOffset: Int
        let hashLength: Int

        // Tried R1 → R2 → R3 → R4: SHA-256 (r1/r2, hash 0x20) then SHA-384
        // (r3/r4, hash 0x30); r1/r3 extended (0x48/0x58), r2/r4 compact (0x30/0x40).
        static let r1 = Spec(stride: 0x48, extended: true, hashOffset: 0x28, hashLength: 0x20)
        static let r2 = Spec(stride: 0x30, extended: false, hashOffset: 0x10, hashLength: 0x20)
        static let r3 = Spec(stride: 0x58, extended: true, hashOffset: 0x28, hashLength: 0x30)
        static let r4 = Spec(stride: 0x40, extended: false, hashOffset: 0x10, hashLength: 0x30)
    }

    /// A row's overridable scalars; nil picks the fixture default (distinct
    /// `DEV_ID` per row, ascending hash bytes 01 02 … from the row's index).
    struct Row {
        var unknown0: UInt32? = nil
        var deviceID: UInt16? = nil
        var vendorID: UInt16 = 0x8086
        var sizeUncompressed: UInt32? = nil
        var sizeCompressed: UInt32? = nil
        var hash: [UInt8]? = nil
    }

    static func put16(_ value: UInt16, in data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }

    static func put32(_ value: UInt32, in data: inout Data, at offset: Int) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data[offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// A run of `rows` contiguous metadata entries in the given struct layout.
    static func table(_ spec: Spec, rows: [Row] = [Row()]) -> Data {
        var data = Data()
        for (index, row) in rows.enumerated() {
            var bytes = Data(repeating: 0, count: spec.stride)
            put32(row.unknown0 ?? UInt32(0x0102_0304 + index), in: &bytes, at: 0x00)
            put16(row.deviceID ?? UInt16(0x1234 + index), in: &bytes, at: 0x04)
            put16(row.vendorID, in: &bytes, at: 0x06)
            put32(row.sizeUncompressed ?? 0x0002_0000, in: &bytes, at: 0x08)
            put32(row.sizeCompressed ?? 0x0001_8000, in: &bytes, at: 0x0C)
            if spec.extended {
                put32(0x0000_4000, in: &bytes, at: 0x10)   // BSSSize
                put32(0x0002_0000, in: &bytes, at: 0x14)   // CodeSizeUncomp
                put32(0x0000_1000, in: &bytes, at: 0x18)   // CodeBaseAddress
                put32(0x0000_2000, in: &bytes, at: 0x1C)   // MainThreadEntry
                put32(0x0000_0000, in: &bytes, at: 0x20)   // Unknown1
                put32(0x0000_0000, in: &bytes, at: 0x24)   // Unknown2
            }
            let hash = row.hash ?? (0..<spec.hashLength).map { UInt8(index + $0 + 1) }
            bytes.replaceSubrange(spec.hashOffset..<(spec.hashOffset + hash.count),
                                  with: hash)
            data.append(bytes)
        }
        return data
    }
}

final class RBEPMMetadataDecodeTests: XCTestCase {
    /// Upstream `'%0.*X' % (len*2, int.from_bytes(Hash, 'little'))` for the
    /// default row-0 hash bytes 01 02 … 20: the LE integer hex = bytes reversed.
    private static let row0HashHex =
        "201F1E1D1C1B1A191817161514131211100F0E0D0C0B0A090807060504030201"

    func testDecodesR1ExtendedTable() throws {
        let entries = try XCTUnwrap(
            RBEPMMetadataParser.decode(in: RBEPMFixture.table(.r1, rows: [.init(), .init(), .init()])))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.id), [0, 1, 2])
        XCTAssertEqual(entries.map(\.variant), [.r1, .r1, .r1])
        XCTAssertEqual(entries.map(\.deviceID), [0x1234, 0x1235, 0x1236])

        let row = entries[0]
        XCTAssertEqual(row.unknown0, 0x0102_0304)
        XCTAssertEqual(row.vendorID, 0x8086)
        XCTAssertEqual(row.sizeUncompressed, 0x0002_0000)
        XCTAssertEqual(row.sizeCompressed, 0x0001_8000)
        // r1 is extended: the six trailing fields decode…
        XCTAssertEqual(row.bssSize, 0x4000)
        XCTAssertEqual(row.codeSizeUncompressed, 0x20000)
        XCTAssertEqual(row.codeBaseAddress, 0x1000)
        XCTAssertEqual(row.mainThreadEntry, 0x2000)
        XCTAssertEqual(row.unknown1, 0)
        XCTAssertEqual(row.unknown2, 0)
        XCTAssertEqual(row.hash, Self.row0HashHex)
    }

    func testDecodesR2CompactTable() throws {
        let entries = try XCTUnwrap(
            RBEPMMetadataParser.decode(in: RBEPMFixture.table(.r2, rows: [.init(), .init(), .init()])))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.variant), [.r2, .r2, .r2])
        // Compact layout stops after SizeComp: no extended fields, hash at 0x10.
        let row = entries[0]
        XCTAssertEqual(row.deviceID, 0x1234)
        XCTAssertEqual(row.sizeCompressed, 0x0001_8000)
        XCTAssertNil(row.bssSize)
        XCTAssertNil(row.codeSizeUncompressed)
        XCTAssertNil(row.mainThreadEntry)
        XCTAssertEqual(row.hash.count, 64)      // SHA-256 → 0x20 bytes
        XCTAssertEqual(row.hash, Self.row0HashHex)
    }

    func testDecodesR3ExtendedSHA384Table() throws {
        let entries = try XCTUnwrap(
            RBEPMMetadataParser.decode(in: RBEPMFixture.table(.r3, rows: [.init(), .init(), .init()])))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].variant, .r3)
        XCTAssertEqual(entries[0].bssSize, 0x4000)          // extended
        XCTAssertEqual(entries[0].hash.count, 96)           // SHA-384 → 0x30 bytes
        XCTAssertEqual(entries[0].hash.prefix(2), "30")     // LE-int hex: 0x30 first
        XCTAssertEqual(entries[0].hash.suffix(2), "01")
    }

    func testDecodesR4CompactSHA384Table() throws {
        let entries = try XCTUnwrap(
            RBEPMMetadataParser.decode(in: RBEPMFixture.table(.r4, rows: [.init(), .init(), .init()])))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].variant, .r4)
        XCTAssertNil(entries[0].bssSize)                    // compact
        XCTAssertEqual(entries[0].hash.count, 96)
        XCTAssertEqual(entries[0].hash.prefix(2), "30")
    }

    func testPicksCompactLayoutBySpacing() throws {
        // All four layouts key on the 0x8086 spacing; only the variant whose
        // stride matches the built table decodes (R1's 0x48 spacing can't match
        // an R2 0x30 table, etc.).
        for (spec, expected) in [(RBEPMFixture.Spec.r1, RBE_PMVariant.r1),
                                 (.r2, .r2), (.r3, .r3), (.r4, .r4)] {
            let entries = try XCTUnwrap(RBEPMMetadataParser.decode(
                in: RBEPMFixture.table(spec, rows: [.init(), .init(), .init()])))
            XCTAssertEqual(entries[0].variant, expected)
        }
    }

    func testChainsContiguousEntriesThenStopsAtForeignVendor() throws {
        // Four rows: the first three are 0x8086 (enough for the pattern) and a
        // fourth whose VEN_ID is not Intel's — the walk stops there, so only
        // three entries are surfaced.
        var foreign = RBEPMFixture.Row()
        foreign.vendorID = 0x9999
        let entries = try XCTUnwrap(RBEPMMetadataParser.decode(
            in: RBEPMFixture.table(.r1, rows: [.init(), .init(), .init(), foreign])))

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.deviceID), [0x1234, 0x1235, 0x1236])
    }

    func testFindsTableBuriedInLargerBody() throws {
        // Preamble of noise before the table: the scan steps byte-by-byte, so
        // only the true spaced-0x8086 run decodes (at body offset 0x40).
        var body = Data(repeating: 0xAA, count: 0x40)
        body.append(RBEPMFixture.table(.r1, rows: [.init(), .init(), .init()]))

        let entries = try XCTUnwrap(RBEPMMetadataParser.decode(in: body))
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].deviceID, 0x1234)
        XCTAssertEqual(entries[0].variant, .r1)
    }

    func testDecodePrefersFirstMatchingLayout() throws {
        // Determinism: within one body only the matching spacing yields rows, and
        // get_rbe_pm_met returns the first (R1) that fits. An R1 table is not
        // also readable as R2 — verify the spacing really selects.
        let body = RBEPMFixture.table(.r2, rows: [.init(), .init(), .init()])
        let entries = try XCTUnwrap(RBEPMMetadataParser.decode(in: body))
        XCTAssertEqual(entries[0].variant, .r2)
        XCTAssertEqual(entries.count, 3)
    }

    func testReturnsNilWithoutThreeSpacedVendors() {
        // A two-row table never establishes the three-consecutive pattern; a
        // body of uniform bytes has no 0x86 0x80 at all.
        XCTAssertNil(RBEPMMetadataParser.decode(
            in: RBEPMFixture.table(.r2, rows: [.init(), .init()])))
        XCTAssertNil(RBEPMMetadataParser.decode(in: Data(repeating: 0x00, count: 0x200)))
        XCTAssertNil(RBEPMMetadataParser.decode(in: Data(repeating: 0x55, count: 0x200)))
        XCTAssertNil(RBEPMMetadataParser.decode(in: Data(count: 0x20)))
    }
}

final class RBEPMAnalyzerTests: XCTestCase {
    /// A stub data source — tests never touch the network (async-api §Testing seam).
    private struct StubSource: MEADataSource {
        let databaseResult: Result<MEADatabase, MEADataError>

        func database() async throws -> MEADatabase {
            try databaseResult.get()
        }
    }

    func testAnalyzeDecodesUncompressedPMR1Metadata() async throws {
        // An FTPR $CPD whose `pm` module body (uncompressed, placed right after
        // the manifest module) holds an R1 metadata table. The decode is purely
        // structural — no DB lines, no dictionary fetch, no Huffman — so a plain
        // offline-capable stub suffices.
        let body = RBEPMFixture.table(.r1, rows: [.init(), .init(), .init()])
        let manifest = ManifestFixture.manifest()
        let manifestBase = 0x10 + 2 * 0x18          // R1 $CPD header + two entries
        let pmBase = manifestBase + manifest.count
        var region = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2", "pm"],
                                     moduleLayout: [
                                        (offset: UInt32(manifestBase), size: UInt32(manifest.count)),
                                        (offset: UInt32(pmBase), size: UInt32(body.count)),
                                     ])
        region.append(manifest)
        region.append(body)
        let analyzer = MEFirmwareAnalyzer(data: StubSource(
            databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0x1000)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.modules.map(\.name), ["$MN2", "pm"])
        let entries = try XCTUnwrap(result.rbePmMetadata)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].variant, .r1)
        XCTAssertEqual(entries[0].deviceID, 0x1234)
        XCTAssertEqual(entries[0].vendorID, 0x8086)
        XCTAssertEqual(entries[2].hash.count, 64)
    }

    func testAnalyzeLeavesRBE_PMNilWithoutPMOrRBEModule() async throws {
        // No `pm`/`rbe` module in the operational partition → no metadata table,
        // and no dictionary fetch is attempted.
        var region = CPDFixture.make(name: "FTPR", moduleNames: ["$MN2"])
        region.append(ManifestFixture.manifest())
        let analyzer = MEFirmwareAnalyzer(data: StubSource(
            databaseResult: .success(MEADatabase(revision: 378))))

        let result = try await analyzer.analyze(region: region, baseOffset: 0)

        let cp = try XCTUnwrap(result.codePartition)
        XCTAssertEqual(cp.modules.map(\.name), ["$MN2"])
        XCTAssertNil(result.rbePmMetadata)
    }
}
