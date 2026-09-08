import XCTest
import Foundation
@testable import MEFirmware

/// Builds a synthetic $MN2/$MAN manifest (struct base = 0 of the returned Data).
/// Layout mirrors `MN2_Manifest_R1` (MEA.py:835) — version/SVN/date fields are
/// identical across R0/R1/R2; the RSA key is 2048-bit by default (PublicKeySize
/// 0x40 dwords → 0x100 bytes).
enum ManifestFixture {
    enum Format {
        case r0, r1, r2
    }

    struct Params {
        var tag: String = "$MN2"
        var format: Format = .r1
        var flags: UInt32 = 0x1            // PVBit on, Debug off (Production)
        // HeaderLength (dwords @ +0x04) sizes the manifest struct; the 0x284-byte
        // synthetic manifest is 0xA1 dwords, so a CSE extension chain appended
        // after it starts at the right offset (the real layouts are ~0x27x-0x28x).
        var headerLength: UInt32 = 0xA1
        // Date fields are packed-BCD on the wire (nibbles are calendar digits);
        // 0x24/0x03/0x2021 = 24 March 2021.
        var day: UInt8 = 0x24
        var month: UInt8 = 0x03
        var year: UInt16 = 0x2021
        var major: UInt16 = 15
        var minor: UInt16 = 40
        var hotfix: UInt16 = 37
        var build: UInt16 = 3121
        var svn: UInt32 = 3
        var meMajor: UInt16 = 15
        var meMinor: UInt16 = 40
        /// R0 VCN (u32 @ +0x34); R1/R2 reuse +0x34 as part of the MEU block, so
        /// the fixture only writes it for `.r0`.
        var vcn: UInt32 = 2
        var publicKeySize: UInt32 = 0x40   // dwords → 0x100 bytes
        var key: [UInt8] = Array(0..<0x100).map { UInt8($0 % 0x100) }
        var signature: [UInt8] = Array(0..<0x100).map { UInt8((0xFF - ($0 % 0x100)) & 0xFF) }
    }

    static func manifest(_ params: Params = Params()) -> Data {
        var data = Data(repeating: 0, count: 0x284)

        func put(_ bytes: [UInt8], at offset: Int) {
            for (i, b) in bytes.enumerated() { data[offset + i] = b }
        }
        func u16(_ value: UInt16, at offset: Int) {
            put([UInt8(value & 0xFF), UInt8(value >> 8)], at: offset)
        }
        func u32(_ value: UInt32, at offset: Int) {
            put([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                 UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)], at: offset)
        }

        let headerVersion: UInt32 = params.format == .r2 ? 0x2_1000 : 0x1_0000
        u32(params.headerLength, at: 0x04)                 // HeaderLength (dwords)
        u32(headerVersion, at: 0x08)                       // HeaderVersion
        u32(params.flags, at: 0x0C)                        // Flags
        u16(0x8086, at: 0x10)                              // VEN_ID — the anchor bytes
        data[0x14] = params.day                            // Day
        data[0x15] = params.month                          // Month
        u16(params.year, at: 0x16)                         // Year
        put(Array(params.tag.utf8), at: 0x1C)              // Tag $MN2/$MAN
        // R0: NumModules at 0x20 (small); R1/R2: BuildTag. Choose so get_manifest
        // picks the requested struct (R0 requires 0 < value < 0x50).
        u32(params.format == .r0 ? 4 : 0x1000_0000, at: 0x20)
        u16(params.major, at: 0x24)                        // Major
        u16(params.minor, at: 0x26)                        // Minor
        u16(params.hotfix, at: 0x28)                       // Hotfix
        u16(params.build, at: 0x2A)                        // Build
        u32(params.svn, at: 0x2C)                          // SVN
        u16(params.meMajor, at: 0x30)                      // MEU_Major (R1/R2)
        u16(params.meMinor, at: 0x32)                      // MEU_Minor (R1/R2)
        if params.format == .r0 {
            u32(params.vcn, at: 0x34)                      // R0 VCN (ME 7-10)
        }
        u32(params.publicKeySize, at: 0x78)                // PublicKeySize (dwords)
        u32(1, at: 0x7C)                                   // ExponentSize (1 dword)
        put(params.key, at: 0x80)                          // RSAPublicKey
        put([0x01, 0x00, 0x01, 0x00], at: 0x180)           // RSAExponent (65537, LE)
        put(params.signature, at: 0x184)                   // RSASignature
        return data
    }

    /// A region whose manifest struct base sits at `manifestBase`, so the anchor
    /// scan must find it past leading filler.
    static func region(withManifestBase manifestBase: Int,
                       params: Params = Params()) -> Data {
        var data = Data(repeating: 0, count: manifestBase)
        data.append(manifest(params))
        return data
    }
}

final class ManifestParserTests: XCTestCase {
    func testDecodesR1CSEVersionMEUAndRSA() throws {
        let region = ManifestFixture.manifest()
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: region))

        XCTAssertEqual(manifest.base, 0)
        XCTAssertEqual(manifest.tag, "$MN2")
        XCTAssertEqual(manifest.format, .r1)
        XCTAssertEqual(manifest.major, 15)
        XCTAssertEqual(manifest.minor, 40)
        XCTAssertEqual(manifest.hotfix, 37)
        XCTAssertEqual(manifest.build, 3121)
        XCTAssertEqual(manifest.meMajor, 15)      // MEU block read for R1
        XCTAssertEqual(manifest.meMinor, 40)
        XCTAssertEqual(manifest.svn, 3)
        XCTAssertEqual(manifest.pvBit, true)
        XCTAssertEqual(manifest.debugSigned, false)
        // BCD date: 0x24 / 0x03 / 0x2021 decode to 24 March 2021.
        XCTAssertEqual(manifest.day, 24)
        XCTAssertEqual(manifest.month, 3)
        XCTAssertEqual(manifest.year, 2021)

        let key = try XCTUnwrap(manifest.rsaPublicKey)
        let sig = try XCTUnwrap(manifest.rsaSignature)
        XCTAssertEqual(key.count, 0x100)
        XCTAssertEqual(key, Data(Array(0..<0x100).map { UInt8($0 % 0x100) }))
        XCTAssertEqual(sig.count, 0x100)
    }

    func testFindsManifestNotAtRegionStart() throws {
        let region = ManifestFixture.region(withManifestBase: 0x100)
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: region))
        XCTAssertEqual(manifest.base, 0x100)
        XCTAssertEqual(manifest.major, 15)
    }

    func testR0HasNoMEUFields() throws {
        var params = ManifestFixture.Params()
        params.format = .r0
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: ManifestFixture.manifest(params)))
        XCTAssertEqual(manifest.format, .r0)
        XCTAssertNil(manifest.meMajor)            // R0 reuses 0x30 as SVN_8/VCN
        XCTAssertNil(manifest.meMinor)
        XCTAssertEqual(manifest.vcn, 2)           // R0 VCN read from +0x34
    }

    func testR1HasNoVCNField() throws {
        var params = ManifestFixture.Params()
        params.vcn = 7
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: ManifestFixture.manifest(params)))
        XCTAssertEqual(manifest.format, .r1)
        XCTAssertEqual(manifest.meMajor, 15)      // MEU block read for R1
        XCTAssertNil(manifest.vcn)                // +0x34 is inside the MEU block, not VCN
    }

    func testDebugSignedFlagSetsReleaseBit() throws {
        var params = ManifestFixture.Params()
        params.flags = 0x8000_0001                // Debug (bit31) + PV
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: ManifestFixture.manifest(params)))
        XCTAssertTrue(manifest.debugSigned)
        XCTAssertTrue(manifest.pvBit)
    }

    func test$MANTagDecodes() throws {
        var params = ManifestFixture.Params()
        params.tag = "$MAN"
        let manifest = try XCTUnwrap(ManifestParser.parseFirst(in: ManifestFixture.manifest(params)))
        XCTAssertEqual(manifest.tag, "$MAN")
    }

    func testEmptyRegionHasNoManifest() {
        XCTAssertNil(ManifestParser.parseFirst(in: Data(repeating: 0xFF, count: 0x300)))
    }

    func testDateFallsBackToRawWhenNotBCD() {
        // 0x07E9 has a nibble > 9 (0xE) so it is not valid BCD; the decoder must
        // keep the raw little-endian value (0x07E9 = 2025) instead of mangling it.
        var params = ManifestFixture.Params()
        params.year = 0x07E9
        let manifest = try! XCTUnwrap(ManifestParser.parseFirst(in: ManifestFixture.manifest(params)))
        XCTAssertEqual(manifest.year, 2025)
    }
}
