import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §7.6 / §15: the pane's status bar carries the typing-mode indicator — `OVR`
/// in the bar's quiet grey, `INS` in the insert caret's red. The mode is not a
/// property of the file, so the indicator follows the mode with or without one
/// open, and it flips the moment the mode does, without waiting for an edit.
@MainActor
final class TypingModeIndicatorTests: XCTestCase {
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        let pane = FilePaneView(viewModel: viewModel)
        pane.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        pane.layoutSubtreeIfNeeded()
        return (pane, viewModel, url)
    }

    /// Red is judged the way the caret tests judge it: red minus blue, in
    /// device RGB. `secondaryLabelColor` is neutral grey, `systemRed` is not.
    private func redness(_ colour: NSColor?) -> CGFloat {
        guard let rgb = colour?.usingColorSpace(.deviceRGB) else { return 0 }
        return rgb.redComponent - rgb.blueComponent
    }

    /// The indicator in both of its states, in the pane it belongs to: a fresh
    /// pane sits in overwrite mode and says so quietly, turning insert mode on
    /// makes it red, and turning it off goes back.
    func testTheStatusBarShowsOVRInGreyAndINSInRed() throws {
        let (pane, viewModel, url) = try makePane([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(pane.typingModeLabel.stringValue, "OVR")
        XCTAssertLessThan(redness(pane.typingModeLabel.textColor), 0.2,
                          "overwrite is the quiet default, not a warning")
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Overwrite mode")

        viewModel.isInsertMode = true

        XCTAssertEqual(pane.typingModeLabel.stringValue, "INS")
        XCTAssertGreaterThan(redness(pane.typingModeLabel.textColor), 0.4,
                             "INS is red — the mode grows the file on every keystroke")
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Insert mode")

        viewModel.isInsertMode = false
        XCTAssertEqual(pane.typingModeLabel.stringValue, "OVR")
        XCTAssertLessThan(redness(pane.typingModeLabel.textColor), 0.2)
        XCTAssertEqual(pane.typingModeLabel.accessibilityLabel(), "Overwrite mode",
                       "and the accessibility label goes back with it")
    }

    /// A pane built while the mode is already on shows INS immediately — the
    /// mode is session-global, so a file opened later inherits it.
    func testAPaneOpenedWhileInsertModeIsOnStartsAsINS() throws {
        let url = try tempFile([0x11, 0x22])
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = PaneViewModel()
        viewModel.isInsertMode = true
        try viewModel.open(url: url)

        let pane = FilePaneView(viewModel: viewModel)

        XCTAssertEqual(pane.typingModeLabel.stringValue, "INS")
    }

    /// The mode belongs to a pane, not to the window (§7.6): the Edit menu's
    /// toggle flips the active pane, and the other pane's indicator does not
    /// move. One file can be typed into while the other is read.
    func testTheEditMenuToggleFlipsOnlyTheActivePane() throws {
        let wc = MainWindowController()
        defer { wc.close() }
        let controller = try XCTUnwrap(wc.mainViewController)

        controller.toggleInsertMode(nil)

        XCTAssertTrue(controller.windowModel.pane1.status.isInsertMode, "the active pane")
        XCTAssertFalse(controller.windowModel.pane2.status.isInsertMode, "the other one")

        controller.toggleInsertMode(nil)

        XCTAssertFalse(controller.windowModel.pane1.status.isInsertMode)
        XCTAssertFalse(controller.windowModel.pane2.status.isInsertMode)
    }

}
