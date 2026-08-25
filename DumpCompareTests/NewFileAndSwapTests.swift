import DumpCompareCore
import XCTest
@testable import DumpCompare

/// New features (not in REQUIREMENTS.md): File > New File opens a brand-new
/// untitled in-memory document (nothing on disk until the first Save / Save As)
/// placed with the same rules as Open (§4.1); View > Swap Panels exchanges
/// pane 1 and pane 2, keeping the active document active.
@MainActor
final class NewFileAndSwapTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("new-swap-\(UUID().uuidString)-\(name)")
    }

    /// A real controller in a real window (empty launch state).
    private func makeController() -> (MainViewController, NSWindow) {
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (controller, window)
    }

    /// Close both panes (stops the file watchers) before deleting the files, so
    /// the external-change prompt can't block the test with a modal.
    private func cleanup(_ controller: MainViewController, _ urls: URL...) {
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Opens a real file into pane 1 and renders single-file mode.
    private func openFileIntoPane1(_ controller: MainViewController, _ url: URL) throws {
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
    }

    // MARK: - New File (untitled in-memory document)

    func testNewFileOpensUntitledDocumentIntoEmptyPane() throws {
        let (controller, _) = makeController()
        defer { cleanup(controller) }

        controller.newUntitledDocument()

        XCTAssertEqual(controller.mode, .singleFile)
        XCTAssertTrue(controller.windowModel.pane1.isOpen)
        XCTAssertTrue(controller.windowModel.pane1.isUntitled,
                      "a new file is an in-memory document, not a disk file")
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, "Untitled")
        XCTAssertEqual(controller.windowModel.pane1.fileSize, 0)
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0)
    }

    func testNewFileWhenOnePaneOpenOpensAsPane2() throws {
        let (controller, _) = makeController()
        let urlA = tempURL("a.bin")
        try Data([0x01]).write(to: urlA)
        defer { cleanup(controller, urlA) }
        try openFileIntoPane1(controller, urlA)
        XCTAssertEqual(controller.mode, .singleFile)

        controller.newUntitledDocument()

        XCTAssertEqual(controller.mode, .comparison,
                       "a second document must switch to comparison mode")
        XCTAssertTrue(controller.windowModel.pane2.isOpen)
        XCTAssertTrue(controller.windowModel.pane2.isUntitled)
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, "Untitled")
        XCTAssertEqual(controller.windowModel.activePaneIndex, 1)
    }

    // MARK: - Swap Panels

    func testSwapPanesExchangesDocumentsAndKeepsActiveDocumentActive() throws {
        let (controller, _) = makeController()
        let urlA = tempURL("a.bin")
        let urlB = tempURL("b.bin")
        try Data([0x01]).write(to: urlA)
        try Data([0x02]).write(to: urlB)
        defer { cleanup(controller, urlA, urlB) }

        try openFileIntoPane1(controller, urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        controller.windowModel.setActivePane(1)
        XCTAssertEqual(controller.mode, .comparison)

        controller.swapPanes()

        XCTAssertEqual(controller.mode, .comparison)
        XCTAssertEqual(controller.windowModel.pane1.status.fileName, urlB.lastPathComponent,
                       "the swap must put the old pane 2 file on the left")
        XCTAssertEqual(controller.windowModel.pane2.status.fileName, urlA.lastPathComponent,
                       "the swap must put the old pane 1 file on the right")
        XCTAssertEqual(controller.windowModel.activePaneIndex, 0,
                       "the active pane must follow its document to the new side")
    }

    /// The swap must re-point the VIEWS to the swapped models, not just exchange
    /// the models in the model layer. Swap leaves the mode unchanged, so
    /// `refreshMode()`'s skip-when-unchanged guard would not re-apply — and the
    /// panes (which follow their models) would stay put, desyncing visual
    /// position from model position. A later position-based operation (a drop
    /// onto the right pane) would then hit the model now in the left (§3.3).
    func testSwapPanesRepointsTheViewsToTheSwappedModels() throws {
        let (controller, window) = makeController()
        let urlA = tempURL("a.bin")
        let urlB = tempURL("b.bin")
        try Data([0x01]).write(to: urlA)
        try Data([0x02]).write(to: urlB)
        defer { cleanup(controller, urlA, urlB) }

        try openFileIntoPane1(controller, urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        controller.swapPanes()
        window.layoutIfNeeded()

        let comparison = try descendant(ComparisonView.self, of: window.contentView!)
        XCTAssertTrue(comparison.paneView1.viewModel === controller.windowModel.pane1,
                      "after swap, the left view must display the model that is now pane 1")
        XCTAssertTrue(comparison.paneView2.viewModel === controller.windowModel.pane2,
                      "after swap, the right view must display the model that is now pane 2")
    }

}
