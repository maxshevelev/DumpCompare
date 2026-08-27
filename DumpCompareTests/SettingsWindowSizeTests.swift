import Cocoa
import XCTest
@testable import DumpCompare

/// The Settings window sizes itself to each tab's content: the width is the
/// tab's fixed width (480, or 620 for Text Decoding), the height is the
/// content's fitting height, and switching tabs resizes the window rather than
/// stretching the tab to the previous tab's size.
@MainActor
final class SettingsWindowSizeTests: XCTestCase {
    /// Clicks the tab's toolbar item — the same path a user click takes, so the
    /// private tab action (which resizes the window) runs for real.
    private func switchTo(_ settings: SettingsWindowController, _ id: String) throws {
        let window = try XCTUnwrap(settings.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let item = try XCTUnwrap(
            settings.toolbar(toolbar, itemForItemIdentifier: NSToolbarItem.Identifier(id),
                             willBeInsertedIntoToolbar: true))
        let target = try XCTUnwrap(item.target as? NSObject)
        target.perform(try XCTUnwrap(item.action))
        window.layoutIfNeeded()
    }

    /// Every tab settles at its own width, not the previous tab's.
    func testEachTabSizesToItsOwnWidth() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        window.makeKeyAndOrderFront(nil)

        let expectedWidth: [(String, CGFloat)] = [
            ("Appearance", 480), ("Layout", 480), ("Comparison", 480),
            ("Editing", 480), ("TextDecoding", 620),
        ]
        for (id, width) in expectedWidth {
            try switchTo(settings, id)
            XCTAssertEqual(window.frame.width, width, accuracy: 1,
                           "\(id) must be \(width) wide")
        }
    }

    /// Returning to a tab must resize the window back to that tab's height —
    /// the window must not keep the previous tab's height.
    func testReturningToATabResizesTheWindow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        window.makeKeyAndOrderFront(nil)

        try switchTo(settings, "TextDecoding")   // the tallest tab
        let tallHeight = window.frame.height
        try switchTo(settings, "Comparison")     // a short tab
        let shortHeight = window.frame.height
        XCTAssertLessThan(shortHeight, tallHeight,
                          "a short tab must be shorter than the tall one")
        try switchTo(settings, "TextDecoding")   // back to the tall tab
        XCTAssertEqual(window.frame.height, tallHeight, accuracy: 1,
                       "returning to a tab must restore its height")
    }
}
