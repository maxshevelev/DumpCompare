import XCTest
import ToolModuleKit
@testable import ByteRipper

/// What a tool-module can see and do through `PaneToolHost`
/// (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolHostTests: XCTestCase {
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

    /// A controller with a file open and a stub session running; the host is
    /// the one that session was handed.
    private func makeHost(_ bytes: [UInt8] = [UInt8](repeating: 0xAA, count: 0x100))
    throws -> (any ToolHost, MainViewController) {
        let url = try tempFile(bytes)
        files.append(url)
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1000, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 600))
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        controller.tools.activate(StubToolA.identifier, animated: false)
        let session = try XCTUnwrap(StubToolA.log.session)
        return (session.host, controller)
    }

    func testItAnswersForTheFileItIsBoundTo() throws {
        let (host, controller) = try makeHost()

        XCTAssertEqual(host.fileName, controller.windowModel.pane1.status.fileName)
        XCTAssertEqual(host.contentSize, 0x100)
        XCTAssertFalse(host.isReadOnly)
    }

    /// The panel has to describe the dump on screen, not the file on disk.
    func testAReadSeesUnsavedEdits() throws {
        let (host, controller) = try makeHost()

        controller.windowModel.pane1.moveCaret(to: 0x10)
        try controller.windowModel.pane1.pasteWrite([0x01, 0x02])

        XCTAssertEqual(try host.read(0x10..<0x12), [0x01, 0x02])
    }

    func testAReadPastTheEndIsRefused() throws {
        let (host, _) = try makeHost()

        XCTAssertThrowsError(try host.read(0xF0..<0x120)) {
            XCTAssertEqual($0 as? ToolHostError, .outsideTheFile)
        }
    }

    /// The point of taking a snapshot: a parse running over it reads the file
    /// as it was when it started, whatever the document does meanwhile.
    func testASnapshotDoesNotMoveWhenTheDocumentDoes() throws {
        let (host, controller) = try makeHost()
        let frozen = try host.snapshot()

        controller.windowModel.pane1.moveCaret(to: 0)
        try controller.windowModel.pane1.pasteWrite([0x55])

        XCTAssertEqual(try frozen.read(0..<1), [0xAA])
        XCTAssertEqual(try host.read(0..<1), [0x55])
        XCTAssertEqual(frozen.size, 0x100)
    }

    /// Reading it from another thread is the whole reason it exists.
    func testASnapshotReadsFromOffTheMainActor() async throws {
        let (host, _) = try makeHost()
        let frozen = try host.snapshot()

        let bytes = await Task.detached { try? frozen.read(0..<4) }.value

        XCTAssertEqual(bytes, [0xAA, 0xAA, 0xAA, 0xAA])
    }

    func testRevealTakesTheDumpToTheRangeAndCanSelectIt() throws {
        let (host, controller) = try makeHost()

        host.reveal(0x40..<0x48, select: true)

        XCTAssertEqual(controller.windowModel.pane1.caretOffset, 0x40)
        XCTAssertEqual(controller.windowModel.pane1.status.selectionLength, 8)
    }

    /// A published map reaches the tab, repaired against the file.
    func testAPublishedMapReachesTheTabClampedToTheFile() throws {
        let (host, controller) = try makeHost()

        host.publish(ZoneMap(zones: [Zone(id: "a", name: "Header", range: 0..<0x10),
                                     Zone(id: "b", name: "Past it", range: 0x200..<0x300)],
                             focus: "b"))

        XCTAssertEqual(controller.tools.zones.zones.map(\.id), ["a"])
        XCTAssertNil(controller.tools.zones.focus)
    }

    /// A parse that finishes after its session ended must not repaint the dump
    /// for a tool-module that is no longer open.
    func testAPublishFromAnEndedSessionIsDropped() throws {
        let (host, controller) = try makeHost()
        host.publish(ZoneMap(zones: [Zone(id: "a", name: "Header", range: 0..<0x10)]))
        controller.tools.activate(nil, animated: false)

        host.publish(ZoneMap(zones: [Zone(id: "late", name: "Too late", range: 0..<0x10)]))

        XCTAssertTrue(controller.tools.zones.zones.isEmpty)
    }

    /// The pane went; every question about it now fails rather than being
    /// answered about a file that is not there.
    func testWithTheFileClosedTheHostRefusesToRead() throws {
        let (host, controller) = try makeHost()
        controller.windowModel.pane1.close()

        XCTAssertThrowsError(try host.read(0..<1)) {
            XCTAssertEqual($0 as? ToolHostError, .noFile)
        }
        XCTAssertEqual(host.contentSize, 0)
    }
}
