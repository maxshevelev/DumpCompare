import XCTest
import ToolModuleKit
@testable import ZoneSketch

/// The sketch's decisions, without a window.
final class ZoneSketchModelTests: XCTestCase {

    func testAddedZonesAreNamedInOrderAndTheNewestIsFocused() {
        var model = ZoneSketchModel()

        model.add(0x00..<0x10)
        model.add(0x20..<0x30)

        XCTAssertEqual(model.zones.map(\.name), ["Zone 1", "Zone 2"])
        XCTAssertEqual(model.focused?.name, "Zone 2")
    }

    /// A zone is a stretch: a caret is not one.
    func testAnEmptyRangeMakesNothing() {
        var model = ZoneSketchModel()

        XCTAssertNil(model.add(0x10..<0x10))
        XCTAssertTrue(model.zones.isEmpty)
    }

    /// A name is never reused inside a session, even after a removal — two
    /// rows called "Zone 2" would be two rows the focus cannot tell apart.
    func testANameIsNotReusedAfterARemoval() {
        var model = ZoneSketchModel()
        model.add(0x00..<0x10)
        model.add(0x20..<0x30)

        model.remove("sketch-2")
        model.add(0x40..<0x50)

        XCTAssertEqual(model.zones.map(\.name), ["Zone 1", "Zone 3"])
    }

    func testRemovingTheFocusedZoneMovesTheFocusRatherThanLosingIt() {
        var model = ZoneSketchModel()
        model.add(0x00..<0x10)
        let second = model.add(0x20..<0x30)

        model.remove(second!.id)

        XCTAssertEqual(model.focused?.name, "Zone 1")
    }

    /// A row that says nothing is worse than one that says "Zone 3".
    func testAnEmptyNameIsRefused() {
        var model = ZoneSketchModel()
        let zone = model.add(0x00..<0x10)!

        model.rename(zone.id, to: "   ")

        XCTAssertEqual(model.zones.first?.name, "Zone 1")
    }

    func testRenamingTrimsAndKeeps() {
        var model = ZoneSketchModel()
        let zone = model.add(0x00..<0x10)!

        model.rename(zone.id, to: "  ME region ")

        XCTAssertEqual(model.zones.first?.name, "ME region")
    }

    /// A focus pointing at a zone that has gone is no focus at all.
    func testFocusingSomethingThatIsNotThereClearsIt() {
        var model = ZoneSketchModel()
        model.add(0x00..<0x10)

        model.focus("nobody")

        XCTAssertNil(model.focus)
    }

    /// The map is what the dump draws: the zones and which one is focused.
    func testTheMapCarriesTheZonesAndTheFocus() {
        var model = ZoneSketchModel()
        model.add(0x00..<0x10)
        let second = model.add(0x20..<0x30)!

        XCTAssertEqual(model.map.zones.count, 2)
        XCTAssertEqual(model.map.focus, second.id)
    }

    /// The fill is one transaction over exactly the zone, named so the menu can
    /// say what it will take back.
    func testTheFillCoversTheZoneAndNamesItself() throws {
        var model = ZoneSketchModel()
        let zone = model.add(0x40..<0x44)!
        model.rename(zone.id, to: "Padding")

        let transaction = try XCTUnwrap(model.fillFocused(with: 0xFF)?.validated())

        XCTAssertEqual(transaction.name, "Fill Padding")
        XCTAssertEqual(transaction.writes.count, 1)
        XCTAssertEqual(transaction.writes.first?.offset, 0x40)
        XCTAssertEqual(transaction.writes.first?.bytes, [0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testNothingFocusedFillsNothing() {
        XCTAssertNil(ZoneSketchModel().fillFocused(with: 0xFF))
    }

    /// The saved file says which dump and which offset it came from — a folder
    /// of "Zone 1.bin" is a folder of anonymous files.
    func testTheExportNameCarriesTheDumpAndTheOffset() {
        var model = ZoneSketchModel()
        let zone = model.add(0x1000..<0x1010)!

        XCTAssertEqual(model.exportName(of: zone, in: "bios.rom"),
                       "bios.rom_00001000_Zone 1.bin")
    }

    /// The offsets as the list shows them: inclusive at the end, because that
    /// is how a dialog reads them (§10.1) even though the range is half-open.
    func testTheRangeIsShownWithAnInclusiveEnd() {
        XCTAssertEqual(ZoneSketchModel.rangeText(0x100..<0x110), "100 – 10F")
    }
}
