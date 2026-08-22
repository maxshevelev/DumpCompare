import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §7.3 Fill Selection with…: drives the whole flow through the real
/// `MainViewController` — menu action → sheet (default `FF`) → byte pattern →
/// the selection is filled by repeating the pattern.
@MainActor
final class FillSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // A fill test that submits a pattern persists it; reset so the default
        // ("FF") and the remembered-pattern assertions stay deterministic.
        UserDefaults.standard.removeObject(forKey: FillPatternStore.userDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FillPatternStore.userDefaultsKey)
        super.tearDown()
    }

    private func makeController(_ bytes: [UInt8], selection: SelectionModel) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.windowModel.pane1.setSelection(selection)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    /// The attached sheet's editable bytes field (default `FF`) and OK button.
    private func sheetControls(_ window: NSWindow) throws -> (NSTextField, NSButton) {
        XCTAssertTrue(pumpUntil(2) { window.attachedSheet != nil }, "the fill sheet must attach")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        let field = try XCTUnwrap(descendants(of: content, NSTextField.self).first { $0.isEditable },
                                  "sheet must have an editable bytes field")
        let ok = try XCTUnwrap(descendants(of: content, NSButton.self).first { $0.title == "OK" }, "OK button")
        return (field, ok)
    }

    /// Close the pane and delete the temp file. Closing stops the file watcher:
    /// deleting the file first would fire the external-change prompt, and that
    /// `NSAlert.runModal()` would block the test's main thread forever.
    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The default is `FF`, and submitting fills the selection by repeating it.
    func testFillDefaultsToFF() throws {
        let (controller, window, url) = try makeController(
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
            selection: SelectionModel(start: 1, end: 5, fileSize: 6))
        defer { cleanup(controller, url) }

        controller.fillSelectionWithBytes()

        let (field, ok) = try sheetControls(window)
        XCTAssertEqual(field.stringValue, "FF")
        ok.performClick(nil)

        XCTAssertTrue(pumpUntil(2) { window.attachedSheet == nil }, "the sheet must dismiss after a fill")
        let states = controller.windowModel.pane1.hexByteStates(in: 0..<6).map(\.byte)
        XCTAssertEqual(states, [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0x06])
        XCTAssertEqual(controller.windowModel.pane1.fileSize, 6)  // length unchanged
    }

    /// A multi-byte pattern repeats across the selection, truncated at the end.
    func testFillRepeatsMultiBytePattern() throws {
        let (controller, window, url) = try makeController(
            [0x01, 0x02, 0x03, 0x04, 0x05],
            selection: SelectionModel(start: 0, end: 5, fileSize: 5))
        defer { cleanup(controller, url) }

        controller.fillSelectionWithBytes()

        let (field, ok) = try sheetControls(window)
        field.stringValue = "DE AD"
        ok.performClick(nil)

        XCTAssertTrue(pumpUntil(2) { window.attachedSheet == nil })
        let states = controller.windowModel.pane1.hexByteStates(in: 0..<5).map(\.byte)
        XCTAssertEqual(states, [0xDE, 0xAD, 0xDE, 0xAD, 0xDE])
    }

    /// The last valid pattern is remembered and offered next time the dialog opens.
    func testFillRemembersLastPattern() throws {
        let (controller, window, url) = try makeController(
            [0x01, 0x02, 0x03, 0x04, 0x05],
            selection: SelectionModel(start: 0, end: 5, fileSize: 5))
        defer { cleanup(controller, url) }

        // First fill uses "DE AD", which becomes the remembered pattern.
        controller.fillSelectionWithBytes()
        var (field, ok) = try sheetControls(window)
        field.stringValue = "DE AD"
        ok.performClick(nil)
        XCTAssertTrue(pumpUntil(2) { window.attachedSheet == nil })
        XCTAssertEqual(FillPatternStore.last, "DE AD")

        // Reopening the dialog pre-fills the field with the remembered pattern.
        // (The fill consumed the selection, so select a fresh range first.)
        controller.windowModel.pane1.setSelection(SelectionModel(start: 0, end: 2, fileSize: 5))
        controller.fillSelectionWithBytes()
        (field, _) = try sheetControls(window)
        XCTAssertEqual(field.stringValue, "DE AD")
    }

    /// Invalid hex keeps the sheet open with an inline error.
    func testFillInvalidHexKeepsSheetOpen() throws {
        let (controller, window, url) = try makeController(
            [0x01, 0x02, 0x03],
            selection: SelectionModel(start: 0, end: 2, fileSize: 3))
        defer { cleanup(controller, url) }

        controller.fillSelectionWithBytes()

        let (field, ok) = try sheetControls(window)
        field.stringValue = "XY"
        ok.performClick(nil)

        XCTAssertFalse(pumpUntil(1) { window.attachedSheet == nil }, "invalid hex must keep the sheet open")
        let sheet = try XCTUnwrap(window.attachedSheet)
        let labels = descendants(of: try XCTUnwrap(sheet.contentView), NSTextField.self)
        XCTAssertTrue(labels.contains { $0.stringValue.contains("Invalid hex") },
                      "the sheet must explain the invalid input")
        XCTAssertEqual(controller.windowModel.pane1.hexByteStates(in: 0..<3).map(\.byte), [0x01, 0x02, 0x03])
    }

    /// The menu item is disabled without a selection — there is nothing to fill.
    func testFillRequiresSelection() throws {
        let (controller, _, url) = try makeController(
            [0x01, 0x02, 0x03],
            selection: SelectionModel.empty(at: 0, fileSize: 3))
        defer { cleanup(controller, url) }

        let item = NSMenuItem(title: "Fill Selection with…", action: #selector(MainViewController.fillSelectionWithBytes), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item), "fill must be disabled with no selection")

        // And the other half, without which a permanently disabled Fill would
        // pass this test: a selection enables it.
        controller.windowModel.pane1.select(range: 0..<2)
        XCTAssertTrue(controller.validateMenuItem(item), "fill must be offered for a real selection")
    }
}
