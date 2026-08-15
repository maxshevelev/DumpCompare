import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.3 navigation: Next/Previous Difference and Same Block move the caret to
/// the block start and vertically centre it in the pane — the same centring
/// the Find bar applies to a match (§11). The companion pane follows through
/// the synchronized scroll (§9).
@MainActor
final class DiffNavigationTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diff-nav-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        var result: [T] = []
        for sub in view.subviews {
            if let match = sub as? T { result.append(match) }
            result.append(contentsOf: descendants(of: sub, type))
        }
        return result
    }

    /// Pumps the main runloop until `condition` holds or the deadline passes.
    @discardableResult
    private func pumpUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Two 300-row files: a difference at row 100 and a difference at row 250,
    /// both far below the initial viewport. Blocks run
    /// same·diff·same·diff·same (§10.3):
    ///   same [0, 1600) · diff [1600, 1601) · same [1601, 4000)
    ///   · diff [4000, 4001) · same [4001, 4800)
    private func makeLayout() -> (left: [UInt8], right: [UInt8]) {
        var left = [UInt8](repeating: 0x11, count: 300 * 16)
        var right = left
        left[100 * 16] = 0xDE
        right[100 * 16] = 0x00
        left[250 * 16] = 0xBE
        right[250 * 16] = 0x00
        return (left, right)
    }

    /// A real controller in a real window with two files open in comparison
    /// mode (coordinator started), pane 1 active.
    private func makeComparison(_ left: [UInt8], _ right: [UInt8]) throws
        -> (MainViewController, NSWindow, URL, URL) {
        let urlA = try tempFile(left)
        let urlB = try tempFile(right)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        return (controller, window, urlA, urlB)
    }

    /// Close both panes (stops the file watchers) before deleting the files:
    /// deleting first would fire the external-change prompt, whose
    /// `NSAlert.runModal()` blocks the test's main thread.
    private func cleanup(_ controller: MainViewController, _ urlA: URL, _ urlB: URL) {
        controller.windowModel.pane1.close()
        controller.windowModel.pane2.close()
        try? FileManager.default.removeItem(at: urlA)
        try? FileManager.default.removeItem(at: urlB)
    }

    /// Waits for the comparison index to finish building before navigating.
    /// Navigation during the build would fall back to a live scan, which races
    /// the build's cancel/reset teardown on the shared builder actor and can
    /// transiently fail; navigating on the built index is the normal (§10.3)
    /// path the tests exercise. The status-bar summary only appears once the
    /// index is ready (§14.4), so it is the "index ready" signal.
    @discardableResult
    private func waitForIndex(_ window: NSWindow, timeout: TimeInterval = 5) -> Bool {
        let panes = descendants(of: window.contentView!, FilePaneView.self)
        return pumpUntil(timeout) {
            panes.contains { $0.comparisonInfo.contains("differing") }
        }
    }

    /// The pane's vertical scroll puts the given offset's row mid-view — the
    /// same expectation the Find-flow test asserts for a search match.
    private func assertRowCentered(_ window: NSWindow, offset: UInt64, file: StaticString = #filePath, line: UInt = #line) throws {
        let paneView = try XCTUnwrap(descendants(of: window.contentView!, FilePaneView.self).first,
                                     file: file, line: line)
        let hexView = try XCTUnwrap(paneView.scrollView.documentView as? HexView, file: file, line: line)
        let clip = paneView.scrollView.contentView
        let rowFrame = hexView.hexLayout.rowFrame(row: Int(offset / 16))
        let maxY = max(0, hexView.bounds.height - clip.bounds.height)
        let expected = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxY)
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 1.0,
                       "the block start row must be vertically centred in the pane", file: file, line: line)
    }

    /// Next Difference lands on the first difference (row 100) and centres it.
    func testNextDifferenceCentersTheBlockInView() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")

        controller.nextDifference()
        let target = UInt64(100 * 16)
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == target },
                      "nextDifference must land the caret on the first difference")
        try assertRowCentered(window, offset: target)
    }

    /// Previous Difference, from the file end, lands on the second difference
    /// (row 250) and centres it.
    func testPreviousDifferenceCentersTheBlockInView() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        controller.windowModel.pane2.moveCaret(to: UInt64(left.count))

        controller.previousDifference()
        let target = UInt64(250 * 16)
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == target },
                      "previousDifference must land the caret on the previous difference")
        try assertRowCentered(window, offset: target)
    }

    /// Next Same Block lands on the middle same block (starting row 100) and
    /// centres it.
    func testNextSameBlockCentersTheBlockInView() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")

        controller.nextSameBlock()
        let target = UInt64(100 * 16 + 1)
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == target },
                      "nextSameBlock must land the caret on the middle same block")
        try assertRowCentered(window, offset: target)
    }

    /// Previous Same Block, from the file end, lands on the trailing same block
    /// (starting row 250) and centres it.
    func testPreviousSameBlockCentersTheBlockInView() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        controller.windowModel.pane2.moveCaret(to: UInt64(left.count))

        controller.previousSameBlock()
        let target = UInt64(250 * 16 + 1)
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == target },
                      "previousSameBlock must land the caret on the trailing same block")
        try assertRowCentered(window, offset: target)
    }
}
