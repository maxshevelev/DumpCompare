import XCTest
import ToolModuleKit
@testable import ByteRipper

/// What a tool-module's transaction does to the file
/// (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolEditTests: XCTestCase {
    private var files: [URL] = []
    private var controller: MainViewController?
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
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
        files = []
        super.tearDown()
    }

    private func makeHost() throws -> (any ToolHost, MainViewController) {
        let url = try tempFile([UInt8](repeating: 0xFF, count: 0x100))
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 600))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        return (try XCTUnwrap(StubToolA.log.session).host, controller)
    }

    /// The FIT case: four writes that are nowhere near each other land
    /// together, and one ⌘Z takes all four back.
    func testScatteredWritesLandTogetherAndUndoTogether() throws {
        let (host, controller) = try makeHost()
        let pane = controller.windowModel.pane1

        try host.apply(ToolTransaction(name: "Add Microcode", writes: [
            .init(offset: 0x00, bytes: [0x01, 0x02]),
            .init(offset: 0x80, bytes: [0x03]),
            .init(offset: 0xF0, bytes: [0x04])
        ]))

        XCTAssertEqual(try host.read(0x00..<0x02), [0x01, 0x02])
        XCTAssertEqual(try host.read(0x80..<0x81), [0x03])
        XCTAssertEqual(try host.read(0xF0..<0xF1), [0x04])

        try pane.undo()

        XCTAssertEqual(try host.read(0x00..<0x02), [0xFF, 0xFF], "one step took all of it back")
        XCTAssertEqual(try host.read(0x80..<0x81), [0xFF])
        XCTAssertEqual(try host.read(0xF0..<0xF1), [0xFF])
        XCTAssertFalse(pane.status.canUndo, "and there was only ever one step")
    }

    /// The menu says what it will take back, so a write nobody watched being
    /// made is still identifiable afterwards.
    func testTheUndoItemNamesTheTransaction() throws {
        let (host, controller) = try makeHost()
        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(MainViewController.redoEdit),
                                  keyEquivalent: "Z")

        try host.apply(ToolTransaction(name: "Add Microcode", offset: 0x10, bytes: [0xAB]))
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Undo Add Microcode")

        try controller.windowModel.pane1.undo()
        _ = controller.validateMenuItem(redoItem)
        XCTAssertEqual(redoItem.title, "Redo Add Microcode",
                       "a step undone is still the same act by the same name")
    }

    /// Ordinary editing has no name, and the item stays the bare verb.
    func testTypingLeavesTheUndoItemUnnamed() throws {
        let (_, controller) = try makeHost()
        let item = NSMenuItem(title: "Undo", action: #selector(MainViewController.undoEdit),
                              keyEquivalent: "z")

        try controller.windowModel.pane1.pasteWrite([0x01])
        _ = controller.validateMenuItem(item)

        XCTAssertEqual(item.title, "Undo")
    }

    /// Everything that can be wrong is decided before a byte moves.
    func testAWritePastTheEndIsRefusedWithoutTouchingTheFile() throws {
        let (host, controller) = try makeHost()

        XCTAssertThrowsError(try host.apply(ToolTransaction(name: "Too far",
                                                            offset: 0xFE, bytes: [1, 2, 3, 4]))) {
            XCTAssertEqual($0 as? ToolHostError, .outsideTheFile)
        }
        XCTAssertEqual(try host.read(0xFE..<0x100), [0xFF, 0xFF])
        XCTAssertFalse(controller.windowModel.pane1.status.canUndo, "nothing was recorded")
    }

    /// Two writes over one byte is what a mis-computed offset looks like, and
    /// no ordering rule should decide it quietly.
    func testATransactionThatWritesOverItselfIsRefused() throws {
        let (host, controller) = try makeHost()

        XCTAssertThrowsError(try host.apply(ToolTransaction(name: "Overlapping", writes: [
            .init(offset: 0x10, bytes: [1, 2, 3, 4]),
            .init(offset: 0x12, bytes: [9])
        ]))) {
            XCTAssertEqual($0 as? ToolTransactionError, .overlappingWrites(at: 0x12))
        }
        XCTAssertFalse(controller.windowModel.pane1.status.isDirty)
    }

    /// A file the user cannot write is one a tool-module cannot write either.
    func testAReadOnlyFileRefusesTheTransaction() throws {
        let url = try tempFile([UInt8](repeating: 0xFF, count: 0x40))
        files.append(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 900, height: 600)
        window.contentViewController = controller
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        let host = try XCTUnwrap(StubToolA.log.session).host
        XCTAssertTrue(host.isReadOnly, "the premise: the file cannot be written")

        XCTAssertThrowsError(try host.apply(ToolTransaction(name: "Patch",
                                                            offset: 0, bytes: [0x01]))) {
            XCTAssertEqual($0 as? ToolHostError, .readOnly)
        }
        XCTAssertEqual(try host.read(0..<1), [0xFF])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    /// The result has to be visible where the user is looking, not only in the
    /// model: the dump repaints and the pane is dirty.
    func testTheDumpAndTheStatusFollowTheWrite() throws {
        let (host, controller) = try makeHost()
        let pane = controller.windowModel.pane1
        var edited: [Range<UInt64>] = []
        let previous = pane.onEdit
        pane.onEdit = { edit in
            previous?(edit)
            if case .overwrite(let range) = edit { edited.append(range) }
        }

        try host.apply(ToolTransaction(name: "Patch", writes: [
            .init(offset: 0x10, bytes: [0xAB]),
            .init(offset: 0x40, bytes: [0xCD])
        ]))

        XCTAssertEqual(edited, [0x10..<0x41], "one repaint over everything it touched")
        XCTAssertTrue(pane.status.isDirty)
    }

    /// A tool-module hears about its own write like any other edit — it has to,
    /// since what it wrote is what its next read will find.
    func testTheSessionHearsAboutItsOwnWrite() throws {
        let (host, controller) = try makeHost()

        try host.apply(ToolTransaction(name: "Patch", offset: 0x10, bytes: [0xAB]))
        controller.tools.flushPendingChangeForTesting()

        XCTAssertEqual(StubToolA.log.changes, [.edited(0x10..<0x11, sizeDelta: 0)])
    }
}
