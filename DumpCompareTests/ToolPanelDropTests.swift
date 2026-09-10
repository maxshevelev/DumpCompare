import XCTest
import UEFIToolUI
@testable import DumpCompare

/// The tool panel as a drop target.
///
/// The panel is *about* a file and a pane, so the two things a reader can carry
/// there both have an obvious meaning: a file replaces the one the panel is
/// reading, and a pane moves the tool onto it. Its own pane is the one drop it
/// refuses — the tool is already reading that file, and a gesture that changes
/// nothing reads as one that failed.
@MainActor
final class ToolPanelDropTests: XCTestCase {
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
        controller?.windowModel.pane2.close()
        for file in files { try? FileManager.default.removeItem(at: file) }
        if let defaultsName { discardIsolatedDefaults(defaultsName, ToolController.defaults) }
        ToolController.defaults = .standard
        ToolController.changeDelay = 0.15
        controller = nil
        window = nil
        files = []
        super.tearDown()
    }

    /// A window with the UEFI panel open on pane 1, and a second file in pane 2.
    private func openComparison() throws -> MainViewController {
        let controller = MainViewController()
        self.controller = controller
        let window = makeTestWindow(width: 1400, height: 700)
        self.window = window
        window.contentViewController = controller

        let first = try tempFile(UEFITestImage.make())
        let second = try tempFile(UEFITestImage.withTrailingPadding())
        files += [first, second]
        try controller.windowModel.pane1.open(url: first)
        try controller.windowModel.pane2.open(url: second)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        controller.windowModel.setActivePane(0)
        controller.tools.activate(UEFIToolModule.identifier, animated: false)
        window.layoutIfNeeded()
        return controller
    }

    private func panel() throws -> ToolPanelView {
        try XCTUnwrap(controller?.tools.panel)
    }

    /// Dropping a file on the panel replaces the file the panel is reading —
    /// the pane it is bound to, not whichever one happens to be active.
    func testAFileDroppedOnThePanelReplacesTheFileItIsReading() throws {
        let controller = try openComparison()
        let panel = try panel()
        XCTAssertTrue(controller.tools.boundPane === controller.windowModel.pane1)

        let replacement = try tempFile(UEFITestImage.withTrailingPadding())
        files.append(replacement)
        let drag = FakeDraggingInfo(fileURLs: [replacement])

        XCTAssertEqual(panel.draggingEntered(drag), .copy, "a file is taken")
        XCTAssertEqual(panel.dropZoneCaption, "Replace Current File",
                       "and the panel says what letting go would do")
        XCTAssertTrue(panel.performDragOperation(drag))
        window?.layoutIfNeeded()

        XCTAssertEqual(controller.windowModel.pane1.status.fileName,
                       replacement.lastPathComponent,
                       "the pane the panel reads has the new file")
        XCTAssertNil(panel.dropZoneCaption, "and the zone is gone with the drag")
    }

    /// A pane dropped on the panel moves the tool onto it.
    func testAPaneDroppedOnThePanelMovesTheToolToIt() throws {
        let controller = try openComparison()
        let panel = try panel()
        let other = controller.windowModel.pane2
        let drag = FakeDraggingInfo(paneID: other.dragID, copying: false)

        XCTAssertEqual(panel.draggingEntered(drag), .move, "the other pane is taken")
        XCTAssertEqual(panel.dropZoneCaption,
                       "Show UEFI Structure for \(other.status.fileName)",
                       "and the panel says which file it would read")
        XCTAssertTrue(panel.performDragOperation(drag))
        window?.layoutIfNeeded()

        XCTAssertTrue(controller.tools.boundPane === other,
                      "the tool reads the pane that was dropped")
    }

    /// Its own pane is refused: the tool already reads that file.
    func testThePanelRefusesTheParticularPaneItIsAlreadyReading() throws {
        let controller = try openComparison()
        let panel = try panel()
        let own = try XCTUnwrap(controller.tools.boundPane)
        let drag = FakeDraggingInfo(paneID: own.dragID, copying: false)

        XCTAssertEqual(panel.draggingEntered(drag), [], "nothing to do with it")
        XCTAssertTrue(panel.dropZoneIsRefusing,
                      "and the panel says so rather than staying blank")
        XCTAssertFalse(panel.performDragOperation(drag), "letting go does nothing")
        XCTAssertTrue(controller.tools.boundPane === own, "the tool did not move")
    }
}
