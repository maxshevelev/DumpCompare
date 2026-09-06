import XCTest
@testable import UEFIFormat

/// The sixteen bytes, and the mixed-endian text everyone writes them as
/// (`Design/UEFI/UEFI_IMAGE_FORMAT.md` §0).
final class EFIGUIDTests: XCTestCase {
    /// EFI_FIRMWARE_FILE_SYSTEM2_GUID, as it appears in a specification and as
    /// it lies in a volume header. The first three fields are byte-swapped and
    /// the last eight are not — get that backwards and every GUID lookup in the
    /// parser misses.
    private let ffsV2 = "8C8CE578-8A3D-4F1C-9935-896185C32DD3"
    private let ffsV2Bytes: [UInt8] = [
        0x78, 0xE5, 0x8C, 0x8C, 0x3D, 0x8A, 0x1C, 0x4F,
        0x99, 0x35, 0x89, 0x61, 0x85, 0xC3, 0x2D, 0xD3
    ]

    func testTheTextFormLaysTheBytesOutMixedEndian() {
        XCTAssertEqual(EFIGUID(ffsV2)?.bytes, ffsV2Bytes)
    }

    func testTheBytesPrintBackAsTheSameText() {
        XCTAssertEqual(EFIGUID(bytes: ffsV2Bytes).description, ffsV2)
    }

    /// Vendors and specifications disagree about case and braces, and a lookup
    /// table that has to match theirs exactly is a table with a bug waiting.
    func testCaseAndBracesAreAccepted() {
        XCTAssertEqual(EFIGUID("{8c8ce578-8a3d-4f1c-9935-896185c32dd3}"), EFIGUID(ffsV2))
    }

    func testMalformedTextIsRejected() {
        XCTAssertNil(EFIGUID("8C8CE578-8A3D-4F1C-9935-896185C32DD"))    // short field
        XCTAssertNil(EFIGUID("8C8CE578-8A3D-4F1C-9935-896185C32DD3-0")) // extra field
        XCTAssertNil(EFIGUID("8C8CE578_8A3D_4F1C_9935_896185C32DD3"))   // no dashes
        XCTAssertNil(EFIGUID("8C8CE57Z-8A3D-4F1C-9935-896185C32DD3"))   // not hex
        XCTAssertNil(EFIGUID(""))
    }

    func testAZeroGuidIsSixteenZeroBytes() {
        XCTAssertEqual(EFIGUID.zero.bytes, [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(EFIGUID.zero.description, "00000000-0000-0000-0000-000000000000")
    }

    /// Every volume, file and GUID-defined section is identified by comparing
    /// against a table, so two spellings of one GUID must be one value.
    func testTwoSpellingsOfOneGuidAreOneValue() {
        let fromText = EFIGUID(ffsV2)
        let fromBytes = EFIGUID(bytes: ffsV2Bytes)

        XCTAssertEqual(fromText, fromBytes)
        XCTAssertEqual(Set([fromText, fromBytes]).count, 1)
    }
}
