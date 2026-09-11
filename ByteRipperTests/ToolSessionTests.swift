import XCTest
import ToolModuleKit
@testable import ByteRipper

/// The running tool-module: what starts it, what it hears, and what ends it
/// (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolSessionTests: XCTestCase {
    private var files: [URL] = []
    private var controllers: [MainViewController] = []
    private var defaultsName: String?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
        // Delivered when the test asks, rather than after a wait.
        ToolController.changeDelay = 0
    }

    override func tearDown() {
        for controller in controllers {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
        }
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controllers = []
        files = []
        super.tearDown()
    }

    private func file(_ byte: UInt8) throws -> URL {
        let url = try tempFile([UInt8](repeating: byte, count: 0x100))
        files.append(url)
        return url
    }

    private func makeController(comparison: Bool = false) throws -> MainViewController {
        let controller = MainViewController()
        controllers.append(controller)
        let window = makeTestWindow(width: 1000, height: 600)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 600))
        try controller.windowModel.pane1.open(url: try file(0xA0))
        if comparison {
            try controller.windowModel.pane2.open(url: try file(0xB0))
            controller.apply(mode: .comparison)
        } else {
            controller.apply(mode: .singleFile)
        }
        window.layoutIfNeeded()
        return controller
    }

    private func activate(_ module: any ToolModule.Type, in controller: MainViewController) {
        controller.tools.activate(module.identifier, animated: false)
    }

    // MARK: - Starting

    /// The session is built for the pane that is active when it is picked, and
    /// started once its view is in the panel — so a slow first parse runs
    /// against a panel the user can already see.
    func testActivatingStartsASessionOnTheActivePane() throws {
        let controller = try makeController()

        activate(StubToolA.self, in: controller)

        XCTAssertNotNil(controller.tools.session)
        XCTAssertIdentical(controller.tools.boundPane, controller.windowModel.pane1)
        XCTAssertEqual(StubToolA.log.started, 1)
        XCTAssertIdentical(controller.tools.panel.contentView,
                           controller.tools.session?.viewController.view)
    }

    /// One tool-module per tab: picking another ends the first.
    func testPickingAnotherModuleEndsTheFirst() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        activate(StubToolB.self, in: controller)

        XCTAssertEqual(StubToolA.log.stopped, 1)
        XCTAssertEqual(StubToolB.log.started, 1)
        XCTAssertEqual(controller.tools.panel.title, StubToolB.title)
    }

    func testNoneEndsTheSession() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        controller.tools.activate(nil, animated: false)

        XCTAssertEqual(StubToolA.log.stopped, 1)
        XCTAssertNil(controller.tools.session)
        XCTAssertNil(controller.tools.panel.contentView)
    }

    // MARK: - What the session hears

    /// Typing lands one edit per keystroke; the session hears one change, over
    /// the whole stretch they touched.
    func testEditsArriveAsOneChangeOverTheStretchTheyTouched() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        try controller.windowModel.pane1.pasteWrite([0x01])
        controller.windowModel.pane1.moveCaret(to: 0x40)
        try controller.windowModel.pane1.pasteWrite([0x02])
        controller.tools.flushPendingChangeForTesting()

        XCTAssertEqual(StubToolA.log.changes.count, 1)
        guard case .edited(let range, let delta) = StubToolA.log.changes.first else {
            return XCTFail("an edit, not \(String(describing: StubToolA.log.changes.first))")
        }
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(range.upperBound, 0x41)
        XCTAssertEqual(delta, 0, "an overwrite moves nothing")
    }

    /// A tool-module works on the file it was opened for. An edit in the other
    /// pane is not its business.
    func testAnEditInTheOtherPaneIsNotItsBusiness() throws {
        let controller = try makeController(comparison: true)
        controller.windowModel.setActivePane(0)
        activate(StubToolA.self, in: controller)

        try controller.windowModel.pane2.pasteWrite([0xEE])
        controller.tools.flushPendingChangeForTesting()

        XCTAssertTrue(StubToolA.log.changes.isEmpty)
    }

    /// A revert replaces the content wholesale, so nothing read before it can
    /// be relied on.
    func testAReplacedContentArrivesAsAReload() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        controller.windowModel.pane1.onFullInvalidation?()
        controller.tools.flushPendingChangeForTesting()

        XCTAssertEqual(StubToolA.log.changes, [.reloaded])
    }

    /// A reload does not wait in the coalescing window. That window exists so
    /// typing does not mean a parse per keystroke; a file that has just been
    /// opened or replaced has nothing coming behind it to merge with, and
    /// holding it back is the panel sitting blank for the length of the wait.
    func testAReloadReachesTheSessionWithoutWaiting() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        controller.windowModel.pane1.onFullInvalidation?()

        XCTAssertEqual(StubToolA.log.changes, [.reloaded],
                       "no flush: the reload should already be there")
    }

    /// A reload swallows an edit that was still waiting: there is nothing left
    /// to be precise about.
    func testAReloadSwallowsAnEditStillWaiting() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        try controller.windowModel.pane1.pasteWrite([0x01])
        controller.windowModel.pane1.onFullInvalidation?()
        controller.tools.flushPendingChangeForTesting()

        XCTAssertEqual(StubToolA.log.changes, [.reloaded])
    }

    // MARK: - What ends it

    func testClosingTheBoundFileEndsTheSession() throws {
        let controller = try makeController()
        activate(StubToolA.self, in: controller)

        controller.closePane(at: 0)

        XCTAssertEqual(StubToolA.log.stopped, 1)
        XCTAssertNil(controller.tools.session)
        XCTAssertNil(controller.tools.activeIdentifier)
        XCTAssertFalse(controller.tools.isPanelVisible)
    }

    /// The panel belongs to the window, the way its bookmarks do (§20): a pane
    /// moved into another tab leaves it behind, and the destination keeps
    /// whatever it had.
    func testAPaneMovedIntoAnotherTabLeavesTheSessionBehind() throws {
        let source = try makeController(comparison: true)
        let destination = try makeController()
        source.windowModel.setActivePane(1)
        activate(StubToolA.self, in: source)
        XCTAssertIdentical(source.tools.boundPane, source.windowModel.pane2)

        destination.adoptPane(source.releasePane(at: 1), bookmarks: [])

        XCTAssertEqual(StubToolA.log.stopped, 1)
        XCTAssertNil(source.tools.session)
        XCTAssertNil(destination.tools.session, "the destination keeps what it had: nothing")
    }

    /// The one exception, and the one the marks already make: a tab made for
    /// this pane starts with nothing in it, so the tool-module opens again on
    /// the other side and reads afresh.
    func testAPaneTornOffTakesItsToolModuleToTheNewTab() throws {
        let source = try makeController(comparison: true)
        let destination = MainViewController()
        controllers.append(destination)
        source.makeSiblingTab = { destination }
        source.windowModel.setActivePane(1)
        let moved = source.windowModel.pane2
        activate(StubToolA.self, in: source)

        let item = NSMenuItem(title: "Open in New Tab",
                              action: #selector(MainViewController.openPaneInNewTab(_:)),
                              keyEquivalent: "")
        item.representedObject = moved
        source.openPaneInNewTab(item)

        XCTAssertNil(source.tools.activeIdentifier, "the session does not travel")
        XCTAssertEqual(destination.tools.activeIdentifier, StubToolA.identifier)
        XCTAssertIdentical(destination.tools.boundPane, moved)
        XCTAssertEqual(StubToolA.log.started, 2, "it reads afresh on the other side")
    }
}
