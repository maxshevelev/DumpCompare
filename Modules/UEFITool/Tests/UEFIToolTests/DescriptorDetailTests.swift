import XCTest
import UEFIImage
@testable import UEFITool

/// What the descriptor node's detail says beyond its header — the block the
/// reference parser prints under "Descriptor region" (`Design/UEFI_STRUCTURE_TOOL.md`).
final class DescriptorDetailTests: XCTestCase {
    private func detail(_ built: TestUEFI.Built) -> UEFINodeDetail {
        UEFIDetail.build(for: built.node, image: built.image, reader: built.reader)
    }

    private func field(_ detail: UEFINodeDetail, _ label: String) -> String? {
        detail.fields.first { $0.label == label }?.value
    }

    private func table(_ detail: UEFINodeDetail, _ title: String) -> UEFIDetailTable? {
        detail.tables.first { $0.title == title }
    }

    /// The sixteen bytes the descriptor opens with, printed the way a dump
    /// prints them — this is a vector a bench compares against another board's.
    func testTheReservedVectorIsShownAsBytes() {
        let shown = detail(TestUEFI.flashDescriptor())

        XCTAssertEqual(field(shown, "Reserved vector"),
                       "11 00 00 9C 90 02 00 D6 00 00 00 05 FF FF FF FF")
    }

    /// Where each region the descriptor declares begins — its own excluded,
    /// which is this node.
    func testEachRegionsOffsetIsARow() {
        let shown = detail(TestUEFI.flashDescriptor())

        XCTAssertEqual(field(shown, "ME region offset"), "0x1000")
        XCTAssertEqual(field(shown, "BIOS region offset"), "0x600000")
        XCTAssertNil(field(shown, "Descriptor region offset"), "this node is that region")
        XCTAssertNil(field(shown, "GbE region offset"), "a region with no limit is not there")
    }

    /// Each master's masks, in the width the descriptor writes them.
    func testEachMastersAccessMasksAreARow() {
        let shown = detail(TestUEFI.flashDescriptor())

        XCTAssertEqual(field(shown, "BIOS access"), "Read 0xA0 · Write 0x00")
        XCTAssertEqual(field(shown, "ME access"), "Read 0x40 · Write 0x00")
        XCTAssertEqual(field(shown, "GbE access"), "Read 0x80 · Write 0x00")
    }

    /// A version 2 descriptor writes twelve bits, so its masks are three digits
    /// wide and it has an EC master the older one does not.
    func testAVersion2DescriptorWritesThreeDigitMasksAndAnEC() {
        let shown = detail(TestUEFI.flashDescriptor(
            version1: false,
            masters: [(0xFFF, 0xFFF), (0x0D8, 0x0D8), (0x008, 0x008), (0x100, 0x100)]))

        XCTAssertEqual(field(shown, "BIOS access"), "Read 0xFFF · Write 0xFFF")
        XCTAssertEqual(field(shown, "EC access"), "Read 0x100 · Write 0x100")
    }

    /// The access table is a grid, and a permission is a word with a colour:
    /// a column of green with one red in it is the answer to "why can't I
    /// write that region".
    func testTheBiosAccessTableIsAGridOfPermissions() throws {
        let shown = detail(TestUEFI.flashDescriptor())
        let table = try XCTUnwrap(table(shown, "BIOS access table"))

        XCTAssertEqual(table.symbol, "lock.shield")
        XCTAssertEqual(table.columns, ["Region", "Read", "Write"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["Desc", "BIOS", "ME", "GbE", "PDR"])
        // A0h carries none of the region bits (they are the low five) and 00h
        // writes nothing — so the BIOS master may touch only its own region,
        // which is stated rather than read because it owns it. This is the
        // locked-down board of the reference parser's own example.
        XCTAssertEqual(table.rows.map { $0[1].text }, ["No", "Yes", "No", "No", "No"])
        XCTAssertEqual(table.rows.map { $0[2].text }, ["No", "Yes", "No", "No", "No"])
        XCTAssertEqual(table.rows.map { $0[1].tone },
                       [.no, .yes, .no, .no, .no],
                       "and each carries the colour it reads in")
    }

    /// A board that lets its BIOS master into the other regions reads the other
    /// way round — which is the whole reason the table is drawn in colour.
    func testAnOpenBoardsAccessTableReadsGreen() throws {
        // Read and write descriptor, BIOS, ME, GbE and PDR alike.
        let shown = detail(TestUEFI.flashDescriptor(masters: [(0x1F, 0x1F), (0, 0), (0, 0)]))
        let table = try XCTUnwrap(table(shown, "BIOS access table"))

        XCTAssertEqual(table.rows.map { $0[1].text }, ["Yes", "Yes", "Yes", "Yes", "Yes"])
        XCTAssertEqual(table.rows.map { $0[2].tone }, [.yes, .yes, .yes, .yes, .yes])
    }

    /// The chips the firmware was built to drive, named where the catalogue
    /// knows the id.
    func testTheVsccTableIsAGridOfChips() throws {
        let shown = detail(TestUEFI.flashDescriptor())
        let table = try XCTUnwrap(table(shown, "Flash chips in VSCC table"))

        XCTAssertEqual(table.symbol, "memorychip")
        XCTAssertEqual(table.columns, ["JEDEC ID", "Chip"])
        XCTAssertEqual(table.rows.map { $0[0].text }, ["1F4700", "1C7018", "C22019", "EF4019"])
        XCTAssertEqual(table.rows.map { $0[1].text },
                       ["Atmel AT25DF321", "EON EN25QH128",
                        "Macronix MX25L256", "Winbond W25Q256"])
    }

    /// A node that is not a descriptor gets none of this — no tables, and no
    /// rows read from bytes that are not a descriptor's.
    func testOnlyADescriptorCarriesTheDescriptorBlock() {
        let volume = TestUEFI.volume()

        XCTAssertTrue(detail(volume).tables.isEmpty)
        XCTAssertNil(field(detail(volume), "Reserved vector"))
    }
}
