import XCTest
import ToolModuleKit
@testable import DumpCompare

/// The tool-module panel: the split's leading pane, what opens it, how wide it
/// opens, and what it does to the window (`Design/TOOL_MODULES_PLAN.md`).
@MainActor
final class ToolPanelTests: XCTestCase {
    private var defaultsName: String?
    private var url: URL?
    private var controller: MainViewController?

    override func setUp() {
        super.setUp()
        installToolStubs()
        let isolated = isolatedDefaults(for: self)
        defaultsName = isolated.name
        ToolController.defaults = isolated.store
    }

    override func tearDown() {
        controller?.windowModel.pane1.close()
        if let url { try? FileManager.default.removeItem(at: url) }
        if let defaultsName {
            discardIsolatedDefaults(defaultsName, ToolController.defaults)
        }
        ToolController.defaults = .standard
        controller = nil
        url = nil
        super.tearDown()
    }

    /// A window wide enough that a 500 pt panel is not clamped by the dump's
    /// own minimum — the clamp has a test of its own — and narrow enough that
    /// it still fits on a laptop screen once the panel has grown it, which is
    /// what the window-move test needs.
    private func makeController(width: CGFloat = 900) throws -> (MainViewController, NSWindow) {
        let file = try tempFile([UInt8](repeating: 0xFF, count: 0x100))
        url = file
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: width, height: 700)
        window.contentViewController = controller
        // Installing a content view controller resizes the window to the view's
        // own size, so the width this test asked for is set afterwards — and
        // the window is placed with room on its left, since opening the panel
        // moves that edge and a window against the screen's edge would be
        // pushed back the other way.
        window.setContentSize(NSSize(width: width, height: 700))
        if let visible = window.screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 100))
        }
        try controller.windowModel.pane1.open(url: file)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func panelWidth(_ controller: MainViewController) -> CGFloat {
        controller.view.layoutSubtreeIfNeeded()
        return controller.toolPanelWidth()
    }

    // MARK: - Opening and closing

    func testThePanelIsClosedUntilAModuleIsPicked() throws {
        let (controller, _) = try makeController()

        XCTAssertFalse(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), 0)
    }

    func testActivatingAModuleOpensThePanelAtTheWidthItAsksFor() throws {
        let (controller, _) = try makeController()

        controller.tools.activate(StubToolB.identifier, animated: false)

        XCTAssertTrue(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), StubToolB.preferredPanelWidth, accuracy: 1)
    }

    /// What the header answers is *which file* — a session is bound to the pane
    /// it was opened for, so in a comparison the panel and the pane being typed
    /// in can be different files.
    func testTheHeaderNamesTheModuleAndTheFile() throws {
        let (controller, _) = try makeController()

        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(controller.tools.panel.title, StubToolA.title)
        XCTAssertEqual(controller.tools.panel.fileName, controller.windowModel.pane1.status.fileName)
    }

    func testNoneClosesThePanel() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.activate(nil, animated: false)

        XCTAssertFalse(controller.tools.isPanelVisible)
        XCTAssertEqual(panelWidth(controller), 0)
    }

    func testThePanelsCloseButtonIsToolsNone() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.tools.panel.onClose?()

        XCTAssertNil(controller.tools.activeIdentifier)
        XCTAssertFalse(controller.tools.isPanelVisible)
    }

    // MARK: - Width

    /// A FIT table wants twice what a tree does, so the width the user drags is
    /// remembered per tool-module rather than shared.
    func testTheWidthTheUserDragsIsRememberedForThatModuleAlone() throws {
        let (controller, _) = try makeController()
        controller.tools.activate(StubToolA.identifier, animated: false)

        controller.panelSplit.setDividerPosition(360, at: MainViewController.toolDividerIndex)
        controller.tools.activate(StubToolB.identifier, animated: false)
        let widthOfB = panelWidth(controller)
        controller.tools.activate(StubToolA.identifier, animated: false)

        XCTAssertEqual(widthOfB, StubToolB.preferredPanelWidth, accuracy: 1,
                       "B opens at its own width, not at the one dragged for A")
        XCTAssertEqual(panelWidth(controller), 360, accuracy: 1,
                       "A opens where it was left")
    }

    /// The file is what the window is for: the panel stops growing rather than
    /// the dump disappearing.
    func testThePanelNeverSqueezesTheDumpBelowItsMinimum() throws {
        let (controller, _) = try makeController(width: 700)

        controller.tools.activate(StubToolB.identifier, animated: false)

        let width = panelWidth(controller)
        XCTAssertLessThan(width, StubToolB.preferredPanelWidth)
        XCTAssertGreaterThanOrEqual(700 - width, ToolController.minContentWidth)
    }

    /// A drag cannot open a panel that has no tool-module in it.
    func testWhileClosedTheDividerCannotBeDraggedOpen() throws {
        let (controller, _) = try makeController()

        controller.panelSplit.setDividerPosition(300, at: MainViewController.toolDividerIndex)

        XCTAssertEqual(panelWidth(controller), 0)
    }

    // MARK: - The window

    /// Opening the panel grows the window leftwards, so the dump keeps the
    /// width it had and its right edge does not move — the mirror of what the
    /// minimap does on the other side (§19).
    func testOpeningThePanelGrowsTheWindowAndLeavesTheDumpAsWide() throws {
        let (controller, window) = try makeController()
        let before = window.frame
        let contentBefore = controller.contentHost.frame.width

        controller.tools.activate(StubToolA.identifier, animated: false)
        window.layoutIfNeeded()

        XCTAssertEqual(window.frame.maxX, before.maxX, accuracy: 1,
                       "the right edge stays put; the left one carries the change")
        XCTAssertGreaterThan(window.frame.width, before.width)
        XCTAssertEqual(controller.contentHost.frame.width, contentBefore, accuracy: 2,
                       "the dump keeps its width")
    }

    // MARK: - Beside the minimap

    /// Both panels open at once, one on each edge, with the dump between them —
    /// the case that broke when the split gained a third pane and every divider
    /// index moved.
    func testBothPanelsOpenOnTheirOwnEdges() throws {
        let (controller, window) = try makeController(width: 1400)

        controller.tools.activate(StubToolA.identifier, animated: false)
        controller.setMinimapPanelVisible(true, animated: false)
        window.layoutIfNeeded()

        let panel = controller.tools.panel.frame
        let content = controller.contentHost.frame
        let minimap = controller.minimapPanel.frame
        XCTAssertEqual(panel.minX, 0, accuracy: 1)
        XCTAssertLessThanOrEqual(panel.maxX, content.minX)
        XCTAssertLessThanOrEqual(content.maxX, minimap.minX)
        XCTAssertGreaterThan(minimap.width, 0)
        XCTAssertGreaterThan(content.width, 0)
    }
}
