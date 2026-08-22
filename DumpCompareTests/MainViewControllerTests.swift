import AppKit
import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Modal alerts must never block a test run: there is no human to click them,
/// so any `runModal` under XCTest hangs the suite forever. `presentModal`
/// short-circuits to a conservative default, and the file-changed prompt
/// resolves to "keep", so a stray watcher event can neither hang nor mutate a
/// pane mid-test (§5.5).
@MainActor
final class MainViewControllerTests: XCTestCase {
    /// This suite runs under the XCTest runner, so the flag must be true here
    /// (and false in a normal app launch). If detection ever fails, every
    /// `presentModal` starts blocking and the suite hangs again.
    func testRunningUnderXCTestIsDetected() {
        XCTAssertTrue(MainViewController.isRunningTests)
    }

    /// The modal path itself: in test mode `presentModal` returns the passed
    /// default without ever entering `runModal` — which would hang this test.
    func testPresentModalReturnsTestDefault() {
        let alert = NSAlert()
        alert.messageText = "test"
        let response = MainViewController.presentModal(alert, defaultInTest: .alertThirdButtonReturn)
        XCTAssertEqual(response, .alertThirdButtonReturn)
    }

    /// A clean pane with a file-changed event keeps its bytes — the in-test
    /// default is "Keep Current Contents", never "Reload".
    func testExternalChangeOnCleanPaneKeepsContents() throws {
        let controller = MainViewController()
        let url = try tempFile([0x11, 0x22, 0x33])
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)

        controller.presentExternalChange(for: controller.windowModel.pane1)

        let bytes = try XCTUnwrap(controller.windowModel.pane1.byteStorage?.read(at: 0, length: 3))
        XCTAssertEqual(bytes, [0x11, 0x22, 0x33])
    }

    /// A dirty pane with a file-changed event keeps its local edits — the
    /// in-test default is "Keep Local Changes", never reload-and-discard.
    func testExternalChangeOnDirtyPaneKeepsLocalEdits() throws {
        let controller = MainViewController()
        let url = try tempFile([0x11, 0x22, 0x33])
        defer { try? FileManager.default.removeItem(at: url) }
        try controller.windowModel.pane1.open(url: url)
        controller.windowModel.pane1.typeASCII(0x41)  // overwrite byte 0 with 'A'

        controller.presentExternalChange(for: controller.windowModel.pane1)

        let bytes = try XCTUnwrap(controller.windowModel.pane1.byteStorage?.read(at: 0, length: 3))
        XCTAssertEqual(bytes, [0x41, 0x22, 0x33])
    }
}
