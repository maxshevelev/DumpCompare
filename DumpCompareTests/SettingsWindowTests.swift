import Cocoa
import XCTest
@testable import DumpCompare

/// The Settings window's own behaviour (§3.2): it closes on Escape, like a
/// sheet — every preference is applied and persisted live the moment it
/// changes, so there is nothing to confirm or lose.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// `cancelOperation` is the responder-chain hook AppKit sends for Escape.
    /// The Settings window overrides it to close, so a synthetic Esc must take
    /// the window down.
    func testEscapeClosesTheSettingsWindow() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible, "precondition: the window is open")

        window.cancelOperation(nil)

        XCTAssertFalse(window.isVisible, "Escape must close the Settings window")
    }

    /// The window is the `SettingsWindow` subclass (the one that overrides
    /// `cancelOperation`), not a plain `NSWindow` whose default no-ops.
    func testTheWindowIsTheEscClosableSubclass() throws {
        let settings = SettingsWindowController()
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window is SettingsWindow,
                      "the Settings window must be the subclass that closes on Escape")
    }
}
