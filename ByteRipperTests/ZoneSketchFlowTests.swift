import XCTest
import ToolModuleKit
import ZoneSketchUI
@testable import ByteRipper

/// The first real tool-module, end to end in the app: the panel's buttons, the
/// zones in the dump, the named undo step (`Design/TOOL_MODULES_PLAN.md`).
///
/// The stubs prove the seam; this proves the seam carries something. It drives
/// the module's own controls rather than its session, so what is tested is what
/// a user can actually reach.
@MainActor
final class ZoneSketchFlowTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var window: NSWindow?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    private func open() throws -> MainViewController {
        let url = try tempFile([UInt8](repeating: 0xAA, count: 0x200))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1000, height: 700)
        self.window = window
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(ZoneSketchModule.identifier, animated: false)
        window.layoutIfNeeded()
        return controller
    }

    private func button(_ title: String) throws -> NSButton {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSButton.self).first { $0.title == title },
                             "a “\(title)” button in the panel")
    }

    private func table() throws -> NSTableView {
        let panel = try XCTUnwrap(controller?.tools.panel)
        return try XCTUnwrap(descendants(of: panel, NSTableView.self).first)
    }

    /// A demonstration panel, and only that: this build lists it because it is
    /// the build the seam is worked on in. A shipping build does not.
    func testItIsOfferedByADebugBuildAndNotByAShippingOne() {
        XCTAssertTrue(ToolRegistry.builtIn.contains { $0.identifier == ZoneSketchModule.identifier },
                      "a debug build lists Zone Sketch")
        XCTAssertFalse(ToolRegistry.shipping.contains { $0.identifier == ZoneSketchModule.identifier },
                       "a shipping build does not")
        XCTAssertEqual(ToolRegistry.builtIn.count, ToolRegistry.shipping.count + 1,
                       "and the demonstration is the whole of the difference")
    }

    func testAddingFromTheSelectionMarksTheDump() throws {
        let controller = try open()
        controller.windowModel.pane1.select(range: 0x40..<0x60)

        try button("Add from Selection").performClick(nil)

        XCTAssertEqual(controller.windowModel.pane1.zones.zones.map(\.name), ["Zone 1"])
        XCTAssertEqual(controller.windowModel.pane1.zones.zones.first?.range, 0x40..<0x60)
        XCTAssertEqual(try table().numberOfRows, 1)
    }

    /// The row and the dump are one state: picking a row focuses that zone.
    func testPickingARowFocusesThatZoneInTheDump() throws {
        let controller = try open()
        controller.windowModel.pane1.select(range: 0x00..<0x10)
        try button("Add from Selection").performClick(nil)
        controller.windowModel.pane1.select(range: 0x80..<0x90)
        try button("Add from Selection").performClick(nil)

        try table().selectRowIndexes([0], byExtendingSelection: false)

        XCTAssertEqual(controller.windowModel.pane1.zones.focus,
                       controller.windowModel.pane1.zones.zones.first?.id)
    }

    func testRemoveTakesTheZoneOffTheDump() throws {
        let controller = try open()
        controller.windowModel.pane1.select(range: 0x40..<0x60)
        try button("Add from Selection").performClick(nil)

        try button("Remove").performClick(nil)

        XCTAssertTrue(controller.windowModel.pane1.zones.zones.isEmpty)
    }

    /// The write path, from a real module's button: one transaction, one undo
    /// step, and the menu says what it will take back.
    func testFillingAZoneWritesItAndUndoesInOneStep() throws {
        let controller = try open()
        let pane = controller.windowModel.pane1
        pane.select(range: 0x40..<0x44)
        try button("Add from Selection").performClick(nil)

        try button("Fill FF").performClick(nil)

        XCTAssertEqual(try pane.byteStorage?.read(at: 0x40, length: 4), [0xFF, 0xFF, 0xFF, 0xFF])
        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Fill Zone 1")

        try pane.undo()

        XCTAssertEqual(try pane.byteStorage?.read(at: 0x40, length: 4), [0xAA, 0xAA, 0xAA, 0xAA])
        XCTAssertFalse(pane.status.canUndo)
    }

    /// Switching the panel away and back is switching, not starting over: the
    /// zones the user drew by hand are the one thing this tool-module must not
    /// lose to a menu click, and the numbering carries on rather than starting
    /// at one again.
    func testTheSketchIsStillThereAfterSwitchingAwayAndBack() throws {
        let controller = try open()
        controller.windowModel.pane1.select(range: 0x40..<0x60)
        try button("Add from Selection").performClick(nil)

        controller.tools.activate(nil, animated: false)
        controller.tools.activate(ZoneSketchModule.identifier, animated: false)
        window?.layoutIfNeeded()

        XCTAssertEqual(controller.windowModel.pane1.zones.zones.map(\.name), ["Zone 1"])
        XCTAssertEqual(controller.windowModel.pane1.zones.zones.first?.range, 0x40..<0x60)
        XCTAssertEqual(try table().numberOfRows, 1)

        controller.windowModel.pane1.select(range: 0x80..<0x90)
        try button("Add from Selection").performClick(nil)

        XCTAssertEqual(controller.windowModel.pane1.zones.zones.map(\.name), ["Zone 1", "Zone 2"])
    }

    /// Closing the module takes its map with it, whatever the module is.
    func testClosingTheModuleClearsTheMap() throws {
        let controller = try open()
        controller.windowModel.pane1.select(range: 0x40..<0x60)
        try button("Add from Selection").performClick(nil)

        controller.tools.activate(nil, animated: false)

        XCTAssertTrue(controller.windowModel.pane1.zones.zones.isEmpty)
    }
}
