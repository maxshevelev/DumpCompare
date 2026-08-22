import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.3 navigation: Next/Previous Difference and Same Block vertically centre
/// the target row in the pane — the same centring the Find bar applies to a
/// match (§11). Forward navigation lands the caret on the block start; backward
/// navigation lands it on the block end (§10.3). The companion pane follows
/// through the synchronized scroll (§9).
@MainActor
final class DiffNavigationTests: XCTestCase {
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
        // Assigning the contentViewController re-fits the window to the view's
        // fitting size (a tiny pane-sized frame); force the content back to the
        // real size so the split view gives the panes actual heights (§3.3).
        window.setContentSize(NSSize(width: 900, height: 600))
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        // Drive the split view through a few display + runloop turns so the
        // panes get real heights (the same settling LayoutToggleTests uses);
        // otherwise the scroll views sit at zero height and the synchronized
        // scroll (§9) clamps through stale geometry.
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
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

    /// Pressing Previous Difference twice must step past the first-found block
    /// to the one before it — landing past the block's last byte would re-find
    /// the same block instead of moving on.
    func testRepeatedPreviousDifferenceSkipsTheFoundBlock() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        controller.windowModel.pane2.moveCaret(to: UInt64(left.count))

        controller.previousDifference()   // second difference [4000, 4001), last byte 4000
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(250 * 16) },
                      "first previousDifference must land on the second difference")
        controller.previousDifference()   // must skip it and find the first difference
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(100 * 16) },
                      "a repeated previousDifference must find the block before the current one")
    }

    /// Two 300-row files with a "holey" change: three single-byte differences
    /// inside 0x15 bytes at row 100, plus one far away at row 250. Grouping
    /// (§10.3.1) makes the cluster one target, so Next Difference steps change to
    /// change instead of byte to byte.
    private func makeHoleyLayout() -> (left: [UInt8], right: [UInt8]) {
        var left = [UInt8](repeating: 0x11, count: 300 * 16)
        var right = left
        for offset in [100 * 16, 100 * 16 + 5, 101 * 16 + 4, 250 * 16] {
            left[offset] = 0xDE
            right[offset] = 0x00
        }
        return (left, right)
    }

    /// The cluster at row 100 is one press, not three: the second press leaves it
    /// entirely and lands on the far change at row 250 (§10.3.1).
    func testNextDifferenceTreatsNearbyDifferencesAsOneChange() throws {
        let (left, right) = makeHoleyLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")

        controller.nextDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(100 * 16) },
                      "the first press must land on the cluster's first differing byte")
        controller.nextDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(250 * 16) },
                      "the second press must skip the rest of the cluster and find the far change")
    }

    /// Backward: the cluster's LAST differing byte (row 101, byte 4) is one
    /// target, reached in a single press from the far change.
    func testPreviousDifferenceLandsOnTheClustersLastDifferingByte() throws {
        let (left, right) = makeHoleyLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        controller.windowModel.pane2.moveCaret(to: UInt64(left.count))

        controller.previousDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(250 * 16) },
                      "the first press must land on the far change")
        controller.previousDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(101 * 16 + 4) },
                      "the second press must land on the cluster's last differing byte")
        // A third press has nowhere to go: the cluster is one change, so the two
        // earlier differing bytes inside it are not separate targets.
        // Asserted, not waited for: `diffNavigationState` is recomputed
        // synchronously from the caret and answers the same question the command
        // does, so "nowhere to go" is a fact here rather than half a second of
        // hoping nothing happens.
        XCTAssertFalse(controller.diffNavigationState.previousDifference,
                       "with the cluster behind it as one change, there is no earlier target")
        controller.previousDifference()
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, UInt64(101 * 16 + 4),
                       "the bytes inside the cluster must not be separate targets")
    }

    /// The Comparison settings tab's grouping distance reaches an open
    /// comparison live (§10.3.1): two differences 40 bytes apart are one change
    /// at the default distance and two changes at 16 bytes — without reopening
    /// the files.
    func testTheGroupingSettingChangesWhatCountsAsOneChange() throws {
        var left = [UInt8](repeating: 0x11, count: 300 * 16)
        var right = left
        for offset in [100 * 16, 100 * 16 + 40] {
            left[offset] = 0xDE
            right[offset] = 0x00
        }
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer {
            ComparisonSettings.resetToDefaults()
            cleanup(controller, urlA, urlB)
        }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")

        controller.nextDifference()
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(100 * 16) })
        XCTAssertFalse(controller.diffNavigationState.nextDifference,
                       "at the default distance the two differences are one change — nothing ahead")
        controller.nextDifference()
        XCTAssertEqual(controller.windowModel.pane1.caretOffset, UInt64(100 * 16),
                       "so the second press stays where it is")

        ComparisonSettings.set(groupingGap: 16)
        // The observer hands the new distance to the coordinator on the main
        // queue, which re-derives the hunks in the background.
        XCTAssertTrue(pumpUntil(5) {
            controller.nextDifference()
            return controller.windowModel.pane1.caretOffset == UInt64(100 * 16 + 40)
        }, "at 16 bytes the second difference must become its own change")
    }

    /// Same for Previous Same Block: repeated presses walk backward through the
    /// same blocks instead of re-finding the one the caret already sits on.
    func testRepeatedPreviousSameBlockSkipsTheFoundBlock() throws {
        let (left, right) = makeLayout()
        let (controller, window, urlA, urlB) = try makeComparison(left, right)
        defer { cleanup(controller, urlA, urlB) }
        XCTAssertTrue(waitForIndex(window), "the index must finish building before navigation")
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        controller.windowModel.pane2.moveCaret(to: UInt64(left.count))

        controller.previousSameBlock()   // trailing same [4001, 4800), last byte 4799
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(left.count - 1) },
                      "first previousSameBlock must land on the trailing same block's last byte")
        controller.previousSameBlock()   // must skip it and find the middle same block [1601, 4000)
        XCTAssertTrue(pumpUntil(5) { controller.windowModel.pane1.caretOffset == UInt64(4000 - 1) },
                      "a repeated previousSameBlock must find the block before the current one")
    }
}
