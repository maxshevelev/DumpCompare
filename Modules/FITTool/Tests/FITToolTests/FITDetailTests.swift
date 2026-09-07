import XCTest
@testable import FITTool
import UEFIImage

/// What the detail panel says about a row: the entry's own sixteen bytes, and
/// what its address leads to, read rather than assumed.
final class FITDetailTests: XCTestCase {
    private let microcode: UInt64 = 0x2000

    /// The value of the first field with this label, or nil when the row has
    /// no such field.
    private func value(_ detail: FITRowDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    private func detail(_ rows: [TestFIT.Row], contents: [UInt64: [UInt8]] = [:]) -> FITRowDetail? {
        let bytes = TestFIT.image(rows: rows, contents: contents)
        let report = FITReader.read(ImageReader(bytes), image: nil)
        guard let row = report.table?.entries.first else { return nil }
        return FITDetail.build(for: row)
    }

    /// A microcode row says what the row is and what it leads to: the entry's
    /// own fields, then the microcode header read back field by field.
    func testAMicrocodeRowSaysItsFieldsAndItsHeader() {
        let detail = detail(
            [TestFIT.Row(FIT.microcodeType, target: microcode)],
            contents: [microcode: TestFIT.microcode(totalSize: 0x180)]
        )
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.title, "#2 Microcode")
        // The fields open with what the row is, not where it sits.
        XCTAssertEqual(detail!.fields.first?.label, "Type")

        // The row's own sixteen bytes.
        XCTAssertEqual(value(detail!, "Type"), "Microcode · 0x01")
        XCTAssertEqual(value(detail!, "Offset"), "0x00001010")
        XCTAssertEqual(value(detail!, "Address"), "0xFFFF2000")
        XCTAssertEqual(value(detail!, "Size"), "0")
        XCTAssertEqual(value(detail!, "Revision"), "1.00")
        // The checksum byte is the header's, so a row that is not the header
        // does not show one.
        XCTAssertNil(value(detail!, "Checksum"))

        // What the row points at, read from the component.
        XCTAssertEqual(value(detail!, "CPUID"), "806EA")
        XCTAssertEqual(value(detail!, "Update revision"), "0xF0")
        XCTAssertEqual(value(detail!, "Date"), "2019-07-15")
        XCTAssertEqual(value(detail!, "Data size"), "0x40 (64)")
        XCTAssertEqual(value(detail!, "Total size"), "0x180 (384)")
        XCTAssertEqual(value(detail!, "Platform IDs"), "0x1")
        // The microcode's own checksum is a field of the header, so it is
        // shown, with whether the image sums to zero. The test image does.
        XCTAssertTrue(value(detail!, "Image checksum")?.hasSuffix(" (Valid)") ?? false)
    }

    /// The header is a row like any other, but its `Size` counts entries rather
    /// than bytes (§4) and its `Address` is the signature, not a pointer.
    func testTheHeaderRowSaysItsCountAndItsSignature() {
        let bytes = TestFIT.image(rows: [TestFIT.Row(FIT.microcodeType, target: microcode)])
        let header = FITReader.read(ImageReader(bytes), image: nil).table?.rows[0]
        let detail = header.map(FITDetail.build)

        XCTAssertEqual(detail?.title, "#1 FIT Header")
        XCTAssertEqual(value(detail!, "Address"), "_FIT_")
        XCTAssertEqual(value(detail!, "Size"), "2 rows")
        // The checksum byte is the header's, so it is the row that shows one —
        // and the test table's is the one that makes it sum to zero.
        XCTAssertTrue(value(detail!, "Checksum")?.hasSuffix(" (Valid)") ?? false)
        // The header points nowhere, so there are no target fields.
        XCTAssertNil(value(detail!, "Points at"))
        XCTAssertNil(value(detail!, "CPUID"))
    }

    /// A policy row at version 0 keeps an Index/IO register descriptor in the
    /// first eight bytes, and the detail reads it as such rather than as the
    /// pointer it is shaped like (§7.3).
    func testAPolicyRowSaysItsIndexIORegisters() {
        let detail = detail([TestFIT.Row(FIT.tpmPolicyType, address: 0x0002_0001_0000_0080, version: 0)])

        XCTAssertEqual(value(detail!, "Index register"), "0x0080")
        XCTAssertEqual(value(detail!, "Data register"), "0x0000")
        XCTAssertEqual(value(detail!, "Access width"), "1 byte")
        XCTAssertEqual(value(detail!, "Bit position"), "0")
        XCTAssertEqual(value(detail!, "Index"), "0x0002")
    }

    /// A row that points into the image but not at microcode says where, and
    /// how long, when the row's own size field is the only size there is.
    func testARowThatLeadsSomewhereElseSaysWhere() {
        let detail = detail([TestFIT.Row(FIT.startupACMType, target: 0x3000, size: 0x10)])

        // The row's own size field, in bytes.
        XCTAssertEqual(value(detail!, "Size"), "0x100 (256)")
        // What it points at: where in the file, and how long.
        XCTAssertEqual(value(detail!, "Points at"), "unrecognised bytes")
        XCTAssertEqual(value(detail!, "Component"), "0x00003000")
        XCTAssertEqual(value(detail!, "Length"), "0x100 (256)")
    }

    /// A row that points nowhere by design — an empty slot — has no target
    /// fields: the entry's own bytes are the whole of what there is to say.
    func testARowThatPointsNowhereHasNoTargetFields() {
        let detail = detail([TestFIT.Row(FIT.emptyType, address: 0)])

        XCTAssertNil(value(detail!, "Points at"))
        XCTAssertNil(value(detail!, "CPUID"))
        XCTAssertNil(value(detail!, "Index register"))
    }

    /// The detail is empty when there is no row to speak of.
    func testAnEmptyDetailSaysNothing() {
        let detail = FITRowDetail.empty
        XCTAssertTrue(detail.fields.isEmpty)
        XCTAssertTrue(detail.title.isEmpty)
    }
}
