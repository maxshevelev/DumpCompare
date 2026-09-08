import XCTest
import Foundation
@testable import MEFirmware

/// Builds synthetic GSC OROM images that satisfy `orom_pat` (MEA.py 11021) —
/// the fixed 40-byte signature `55 AA {22} 1C 00 {2} PCIR 86 80 {4} (18|1C) 00` —
/// followed by a `GSC_OROM_Header` (0x1C) and its `GSC_OROM_PCI_Data` PCIR
/// struct (0x1C) whose own `PCIDataHdrLen` (header+0x1C+0x0A) carries the
/// 0x18/0x1C that closes the pattern. Field offsets mirror the ctypes structs
/// (MEA.py 433/466) so the decoder and fixture agree byte-for-byte. No real GSC
/// OROM dump exists among the engine's oracles — this is the fixture-only
/// row-30/80 increment.
enum GSCOROMFixture {
    struct Params {
        // GSC_OROM_Header
        var imageSize: UInt16 = 8           // 512-byte blocks → imageSizeBytes 4096
        var initFuncEntryPoint: UInt32 = 0x0000C000
        var subSystem: UInt16 = 0
        var machineType: UInt16 = 0
        var compressionType: UInt16 = 0
        var reserved: UInt64 = 0
        var efiImageOffset: UInt16 = 0
        var pciDataHeaderOffset: UInt16 = 0x1C    // fixed by orom_pat (bytes 24/25)
        var oromPayloadOffset: UInt16 = 0x38      // just past header + PCIR
        // GSC_OROM_PCI_Data
        var deviceID: UInt16 = 0x1918
        var deviceListPointer: UInt16 = 0x38
        var pciDataHeaderLength: UInt16 = 0x18    // fixed by orom_pat (bytes 38/39)
        var pciDataHeaderRevision: UInt8 = 0
        var classCode: UInt32 = 0x000002          // base class 0x02 network
        var imageSizePCI: UInt16 = 8
        var revisionLevel: UInt16 = 1
        var codeType: UInt8 = 0
        var lastImage: Bool = false               // bit 7 of byte +0x15
        var maxRuntimeImageLength: UInt16 = 0x20
        var configUtilityCodeHeaderPointer: UInt16 = 0
        var dmtfCLPEntryPointPointer: UInt16 = 0
        // Payload: "$CPD" opened at data_off = max(0x1C+0x18, efi, orom).
        var payload: Data = Data("$CPD".utf8)
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

    static func setUInt64(_ value: UInt64, in data: inout Data, at offset: Int) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data[offset + shift / 8] = UInt8((value >> shift) & 0xFF)
        }
    }

    /// One complete OROM image: header (0x1C) + PCIR (0x1C) + payload. `payload`
    /// is placed at `data_off = max(pciDataHeaderOffset + pciDataHeaderLength,
    /// efiImageOffset, oromPayloadOffset)` — the decoder's computed split.
    static func image(_ params: Params = Params()) -> Data {
        let payloadOff = Int(max(Int(params.pciDataHeaderOffset) + Int(params.pciDataHeaderLength),
                                 max(Int(params.efiImageOffset), Int(params.oromPayloadOffset))))
        var data = Data(repeating: 0, count: payloadOff + params.payload.count)

        // GSC_OROM_Header @ 0
        setUInt16(0xAA55, in: &data, at: 0x00)            // signature
        setUInt16(params.imageSize, in: &data, at: 0x02)
        setUInt32(params.initFuncEntryPoint, in: &data, at: 0x04)
        setUInt16(params.subSystem, in: &data, at: 0x08)
        setUInt16(params.machineType, in: &data, at: 0x0A)
        setUInt16(params.compressionType, in: &data, at: 0x0C)
        setUInt64(params.reserved, in: &data, at: 0x0E)
        setUInt16(params.efiImageOffset, in: &data, at: 0x16)
        setUInt16(0x1C, in: &data, at: 0x18)               // pciDataHeaderOffset
        setUInt16(params.oromPayloadOffset, in: &data, at: 0x1A)

        // GSC_OROM_PCI_Data @ 0x1C (the "PCIR" the signature asserts at 28–33).
        data[0x1C] = 0x50; data[0x1D] = 0x43
        data[0x1E] = 0x49; data[0x1F] = 0x52               // "PCIR"
        setUInt16(0x8086, in: &data, at: 0x20)             // vendorID (fixed)
        setUInt16(params.deviceID, in: &data, at: 0x22)
        setUInt16(params.deviceListPointer, in: &data, at: 0x24)
        setUInt16(params.pciDataHeaderLength, in: &data, at: 0x26)  // 0x18/0x1C
        data[0x28] = params.pciDataHeaderRevision
        setUInt32(params.classCode, in: &data, at: 0x29)   // 3 LE bytes @ +0x0D
        setUInt16(params.imageSizePCI, in: &data, at: 0x2C)   // PCIR imageSize @ +0x10
        setUInt16(params.revisionLevel, in: &data, at: 0x2E)
        data[0x30] = params.codeType                        // +0x14
        data[0x31] = params.lastImage ? 0x80 : 0x00         // +0x15 LastImageMark
        setUInt16(params.maxRuntimeImageLength, in: &data, at: 0x32)
        setUInt16(params.configUtilityCodeHeaderPointer, in: &data, at: 0x34)
        setUInt16(params.dmtfCLPEntryPointPointer, in: &data, at: 0x36)

        data.replaceSubrange(payloadOff..<(payloadOff + params.payload.count),
                             with: params.payload)
        return data
    }
}

final class GSCOROMDecodeTests: XCTestCase {
    func testDecodesHeaderAndPCIR() throws {
        let images = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image()))
        XCTAssertEqual(images.count, 1)

        let image = images[0]
        XCTAssertEqual(image.id, 0)
        XCTAssertEqual(image.offset, 0)

        // GSC_OROM_Header
        XCTAssertEqual(image.header.signature, 0xAA55)
        XCTAssertEqual(image.header.imageSize, 8)
        XCTAssertEqual(image.header.imageSizeBytes, 4096)   // ImageSize × 512
        XCTAssertEqual(image.header.initFuncEntryPoint, 0x0000C000)
        XCTAssertEqual(image.header.pciDataHeaderOffset, 0x1C)
        XCTAssertEqual(image.header.oromPayloadOffset, 0x38)

        // GSC_OROM_PCI_Data
        XCTAssertEqual(image.pciData.signature, "PCIR")
        XCTAssertEqual(image.pciData.vendorID, 0x8086)
        XCTAssertEqual(image.pciData.deviceID, 0x1918)
        XCTAssertEqual(image.pciData.pciDataHeaderLength, 0x18)
        XCTAssertEqual(image.pciData.classCode, 0x000002)
        XCTAssertEqual(image.pciData.revisionLevel, 1)
        XCTAssertFalse(image.pciData.lastImage)
    }

    func testPayloadOffsetIsMaxOfSplitFields() throws {
        // data_off = max(PCIDataHdrOff + PCIDataHdrLen, EFIImageOffset,
        //                OROMPayloadOff) — MEA.py 12169. With PCIR DataHdrLen 0x18
        // the first term is 0x34; EFIImageOffset 0x40 wins.
        var params = GSCOROMFixture.Params()
        params.efiImageOffset = 0x40
        params.oromPayloadOffset = 0x38
        params.payload = Data("$CPD".utf8)
        let images = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(params)))

        XCTAssertEqual(images[0].payloadOffset, 0x40)
        XCTAssertTrue(images[0].payloadIsCPD)
    }

    func testPayloadOffsetDefaultsPastPCIR() throws {
        // OROMPayloadOff 0x38 (just past header+PCIR) ties the max: header split
        // 0x1C + 0x18 = 0x34 < 0x38.
        let images = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image()))
        XCTAssertEqual(images[0].payloadOffset, 0x38)
    }

    func testPayloadIsCPDFlag() throws {
        var cpd = GSCOROMFixture.Params()
        cpd.payload = Data("$CPD".utf8)
        let yes = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(cpd)))
        XCTAssertTrue(yes[0].payloadIsCPD)

        var notCPD = GSCOROMFixture.Params()
        notCPD.payload = Data("$ABC".utf8)      // wrong magic
        let no = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(notCPD)))
        XCTAssertFalse(no[0].payloadIsCPD)

        var empty = GSCOROMFixture.Params()
        empty.payload = Data()
        let none = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(empty)))
        XCTAssertFalse(none[0].payloadIsCPD)    // no bytes to compare
    }

    func testLastImageReadsBit7() throws {
        var params = GSCOROMFixture.Params()
        params.lastImage = true
        let images = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(params)))
        XCTAssertTrue(images[0].pciData.lastImage)
    }

    func testScanFindsImageBuriedInLargerRegion() throws {
        // Preamble of noise before the image: the scan steps byte-by-byte so only
        // the true orom_pat match decodes.
        var region = Data(repeating: 0xAA, count: 0x80)
        region.append(GSCOROMFixture.image())
        let images = try XCTUnwrap(GSCOROM.decode(in: region))

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].offset, 0x80)
        XCTAssertEqual(images[0].pciData.deviceID, 0x1918)
    }

    func testBaseOffsetShiftsReportedAnchor() throws {
        let images = try XCTUnwrap(GSCOROM.decode(in: GSCOROMFixture.image(),
                                                  baseOffset: 0x1000))
        XCTAssertEqual(images[0].offset, 0x1000)
    }

    func testScansMultipleBackToBackImages() throws {
        var region = GSCOROMFixture.image()          // id 0, offset 0
        var second = GSCOROMFixture.Params()
        second.deviceID = 0x02A0
        region.append(GSCOROMFixture.image(second))  // id 1, offset 0x38 (no payload)
        // The two fixtures place payloads at data_off 0x38 (default, 4 bytes for the
        // first) so the first spans 0x3C; give the region its full extent.
        region.append(Data(repeating: 0xFF, count: 0x10))

        let images = try XCTUnwrap(GSCOROM.decode(in: region))
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.map(\.id), [0, 1])
        XCTAssertEqual(images[0].offset, 0)
        XCTAssertEqual(images[0].pciData.deviceID, 0x1918)
        XCTAssertEqual(images[1].offset, images[0].offset + GSCOROMFixture.image().count)
        XCTAssertEqual(images[1].pciData.deviceID, 0x02A0)
    }

    func testTruncatedPCIRSkipped() throws {
        // A header whose PCIR struct does not fully fit the region cannot be
        // decoded; the scan skips it → nil. The signature (through byte 39) is
        // still readable at 0x30 bytes but decodeImage's guard (header 0x1C +
        // PCIR 0x1C ≤ count) trips on the missing PCIR tail.
        let region = GSCOROMFixture.image().prefix(0x30)
        XCTAssertNil(GSCOROM.decode(in: region))
    }

    func testReturnsNilWhenNoOROMSignature() {
        XCTAssertNil(GSCOROM.decode(in: Data(repeating: 0x55, count: 0x100)))
        XCTAssertNil(GSCOROM.decode(in: Data(repeating: 0x00, count: 0x100)))

        // Signature AA55 but PCIDataHdrOff ≠ 0x1C (byte 25 not 0).
        var wrong = GSCOROMFixture.image()
        wrong[25] = 0x01
        XCTAssertNil(GSCOROM.decode(in: wrong))
    }

    func testReturnsNilForTinyRegion() {
        XCTAssertNil(GSCOROM.decode(in: Data(count: 0x20)))
    }
}
