import XCTest
@testable import FITTool
import UEFIImage

/// What a row points at, checked by reading it (§7, §11).
final class FITTargetTests: XCTestCase {
    private let target: UInt64 = 0x2000

    private func target(_ row: TestFIT.Row, contents: [UInt64: [UInt8]] = [:],
                        image: UEFIImage? = nil) -> FITTarget? {
        let bytes = TestFIT.image(rows: [row], contents: contents)
        return FITReader.read(ImageReader(bytes), image: image).table?.entries.first?.target
    }

    /// A microcode row's own `Size` is required to be zero and the truth is in
    /// the component (§7.1) — which is why the size shown comes from there.
    func testAMicrocodeRowLeadsToItsHeader() {
        let row = TestFIT.Row(FIT.microcodeType, target: target)
        let bytes = TestFIT.image(rows: [row], contents: [target: TestFIT.microcode(totalSize: 0x180)])
        let found = FITReader.read(ImageReader(bytes), image: nil).table?.entries.first

        guard case .microcode(let header) = found?.target else {
            return XCTFail("expected a microcode target")
        }
        XCTAssertEqual(header.processorSignature, 0x0008_06EA)
        XCTAssertEqual(header.totalSize, 0x180)
        XCTAssertEqual(found?.entry.size, 0)
        XCTAssertEqual(found?.effectiveSize, 0x180)
    }

    /// `FF FF FF FF` is a slot a vendor reserved for a later update, and the
    /// specification allows a row to point at one (§7.1). It is not a defect.
    func testAMicrocodeRowMayPointAtAnEmptySlot() {
        let bytes = TestFIT.image(rows: [TestFIT.Row(FIT.microcodeType, target: target)])
        let report = FITReader.read(ImageReader(bytes), image: nil)

        XCTAssertEqual(report.table?.entries.first?.target, .emptyMicrocodeSlot(offset: target))
        XCTAssertFalse(report.problems.contains { $0.severity == .error })
    }

    /// The defect §11 is a post-mortem of: an address off by one hex digit,
    /// landing on bytes that are not microcode and not an empty slot. One read
    /// of forty-eight bytes catches the whole class.
    func testAMicrocodeRowPointingAtSomethingElseIsReported() {
        let bytes = TestFIT.image(
            rows: [TestFIT.Row(FIT.microcodeType, target: target)],
            contents: [target: [UInt8](repeating: 0x5A, count: 0x100)]
        )
        let report = FITReader.read(ImageReader(bytes), image: nil)

        XCTAssertEqual(
            report.table?.entries.first?.target,
            .bytes(offset: target, description: nil)
        )
        XCTAssertTrue(report.problems.contains {
            $0.kind == .notMicrocodeAtTheAddress(address: 0xFFFF_2000) && $0.entryIndex == 1
        })
    }

    /// A policy row at version 0 keeps an Index/IO register descriptor in the
    /// first eight bytes. Reading it as an address is the mistake the format
    /// invites, and it would put the dump somewhere meaningless (§7.3).
    func testAPolicyRowAtVersionZeroIsNotAnAddress() {
        // The first eight bytes, read as a descriptor of Index/IO registers
        // rather than as the pointer they are shaped like (§7.3).
        XCTAssertEqual(
            target(TestFIT.Row(FIT.tpmPolicyType, address: 0x0002_0001_0000_0080, version: 0)),
            .indexIORegisters(FITIndexIODescriptor(
                indexRegister: 0x0080, dataRegister: 0x0000,
                accessWidth: 1, bitPosition: 0, index: 0x0002
            ))
        )
        XCTAssertEqual(
            target(TestFIT.Row(FIT.txtPolicyType, address: 0x1234, version: 0)),
            .indexIORegisters(FITIndexIODescriptor(
                indexRegister: 0x1234, dataRegister: 0,
                accessWidth: 0, bitPosition: 0, index: 0
            ))
        )
    }

    func testAPolicyRowAtVersionOneIsAnAddress() {
        XCTAssertEqual(
            target(TestFIT.Row(FIT.tpmPolicyType, target: target, version: 1)),
            .bytes(offset: target, description: nil)
        )
    }

    func testTheHeaderAndAnEmptySlotPointNowhere() {
        let bytes = TestFIT.image(rows: [TestFIT.Row(FIT.emptyType, address: 0)])
        let table = FITReader.read(ImageReader(bytes), image: nil).table

        XCTAssertEqual(table?.header.map { _ in table!.rows[0].target }, .nothing)
        XCTAssertEqual(table?.entries.first?.target, .nothing)
    }

    func testAnAddressOutsideTheImageLeadsNowhere() {
        XCTAssertEqual(
            target(TestFIT.Row(FIT.startupACMType, address: 0x1234)),
            .outsideTheImage
        )
        XCTAssertEqual(
            target(TestFIT.Row(FIT.startupACMType, address: 0xFFFF_FFFF_FFFF_0000)),
            .outsideTheImage
        )
    }

    /// What the tree says covers the bytes — the difference between an address
    /// and a place.
    func testWhatARowPointsAtIsNamedByTheTree() {
        let node = UEFINode(kind: .volume, name: "FFSv2", range: 0x1800..<0x3000)
        let image = UEFIImage(size: 0x1_0000, roots: [node], addressDiff: 0xFFFF_0000)

        XCTAssertEqual(
            target(TestFIT.Row(FIT.startupACMType, target: target), image: image),
            .bytes(offset: target, description: "FFSv2")
        )
    }

    /// A row whose type does not use `Size` shows nothing rather than a zero
    /// that looks like a size (§11).
    func testARowWithNoSizeShowsNoSize() {
        let bytes = TestFIT.image(rows: [TestFIT.Row(FIT.startupACMType, target: target)])
        let row = FITReader.read(ImageReader(bytes), image: nil).table?.entries.first

        XCTAssertNil(row?.effectiveSize)
    }
}
