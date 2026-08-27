import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.3: the toolbar's Prev/Next Difference arrows dim with the menu items they
/// mirror — no file open, no index yet, or no change in that direction.
///
/// The mechanism matters: AppKit revalidates every visible toolbar item on its
/// own schedule and the default validation only asks "does the target respond to
/// the action", which is always true here. Pushing `isEnabled` onto the items is
/// therefore undone on the next pass; the state has to come from
/// `validateToolbarItem` on the target. These tests read the rendered buttons, so
/// they fail if that stops being true.
@MainActor
final class ToolbarValidationTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The rendered arrow buttons, by the labels their toolbar items carry.
    /// The group has no view of its own — AppKit builds the buttons — so the
    /// accessibility label is the handle onto them.
    private func arrowButtons(_ window: NSWindow) throws -> (prev: NSButton, next: NSButton) {
        let root = try XCTUnwrap(window.contentView?.superview)
        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let prev = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Prev Diff" },
                                 "the toolbar shows the Prev Diff button")
        let next = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Next Diff" },
                                 "the toolbar shows the Next Diff button")
        return (prev, next)
    }

    /// A window controller with the toolbar realised and its items validated.
    private func makeWindow() -> MainWindowController {
        let wc = MainWindowController()
        wc.showWindow(nil)
        let window = wc.window!
        window.setFrame(NSRect(x: 100, y: 100, width: 1080, height: 720), display: true)
        // Three items with no file open — the difference block is not among
        // them outside comparison mode (§10.3).
        _ = pumpUntil(2) { (window.toolbar?.items.count ?? 0) >= 3 }
        window.layoutIfNeeded()
        window.toolbar?.validateVisibleItems()
        return wc
    }

    /// Difference navigation exists only with two files open, so outside
    /// comparison mode the toolbar does not carry the block at all — a pair of
    /// buttons that can never do anything still reads as something the window
    /// offers. The menu items stay, disabled: a menu lists what exists (§10.3).
    func testTheDifferenceBlockIsOnlyInTheToolbarInComparisonMode() throws {
        let wc = makeWindow()
        let controller = wc.mainViewController
        let window = wc.window!
        let urlA = try tempFile([UInt8](repeating: 0x11, count: 64))
        let urlB = try tempFile([UInt8](repeating: 0x22, count: 64))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        // The toolbar is reconfigured a run-loop turn after the mode changes
        // (AppKit will not have it mutated mid-reconfiguration), so each check
        // waits for it.
        func hasBlock() -> Bool {
            window.toolbar?.items.contains { $0.itemIdentifier == .diffNavigation } ?? false
        }

        XCTAssertTrue(pumpUntil(2) { !hasBlock() }, "empty mode: nothing to compare")

        try controller.windowModel.pane1.open(url: urlA)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(2) { !hasBlock() }, "single-file mode: still nothing to compare")

        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(2) { hasBlock() }, "two files: the block appears")
        // And in its place: between the flexible space and the minimap toggle.
        XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier),
                       [.flexibleSpace, .diffNavigation, .space, .toggleMinimap])

        controller.windowModel.pane2.close()
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(2) { !hasBlock() },
                      "closing the second file takes it away again")
    }

    /// In a comparison, each arrow is enabled exactly when it has somewhere to
    /// go — and follows the caret without waiting for AppKit's idle pass.
    func testTheArrowsFollowTheCaretsPositionInTheComparison() throws {
        let wc = makeWindow()
        let window = wc.window!
        let controller = wc.mainViewController
        var left = [UInt8](repeating: 0x11, count: 300 * 16)
        var right = left
        left[100 * 16] = 0xDE
        right[100 * 16] = 0x00
        let urlA = try tempFile(left)
        let urlB = try tempFile(right)
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        // The block is inserted a run-loop turn after the mode change (AppKit
        // will not have the toolbar mutated mid-reconfiguration), so wait for it
        // before reading the rendered buttons.
        XCTAssertTrue(pumpUntil(2) {
            window.toolbar?.items.contains { $0.itemIdentifier == .diffNavigation } ?? false
        }, "the difference block appears in comparison mode")

        let (prev, next) = try arrowButtons(window)
        // The index has to land before navigation is possible at all (§10.3).
        // Both conditions in one wait: the arrows are validated together, and
        // waiting on one of them can catch the state mid-pass.
        XCTAssertTrue(pumpUntil(5) { next.isEnabled && !prev.isEnabled },
                      "Next Diff enables once the index is built and a change lies ahead, "
                      + "while nothing lies behind the caret at offset 0")

        // Jump past the only change: now the arrows swap.
        controller.windowModel.pane1.moveCaret(to: UInt64(left.count))
        XCTAssertTrue(pumpUntil(2) { prev.isEnabled && !next.isEnabled },
                      "at EOF the change lies behind the caret, not ahead")
    }

    // MARK: - The "Files are identical" badge

    private func has(_ window: NSWindow, _ id: NSToolbarItem.Identifier) -> Bool {
        window.toolbar?.items.contains { $0.itemIdentifier == id } ?? false
    }

    /// When the two files are identical, the Prev/Next Difference block is
    /// replaced by the "Files are identical" badge — a green checkmark with the
    /// text, not a pair of buttons that can never do anything. The badge is
    /// index-driven: it appears only once the index has landed and reports no
    /// differences, and it takes the block's slot between the flexible space
    /// and the minimap toggle (§10.3).
    func testIdenticalFilesShowTheBadgeInsteadOfTheArrows() throws {
        let wc = makeWindow()
        let controller = wc.mainViewController
        let window = wc.window!
        let bytes = [UInt8](repeating: 0x11, count: 64)
        let urlA = try tempFile(bytes)
        let urlB = try tempFile(bytes)
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        // The badge waits for the index to land and report no differences.
        XCTAssertTrue(pumpUntil(5) { has(window, .filesIdentical) && !has(window, .diffNavigation) },
                      "identical files: the badge replaces the arrows")
        // And it takes the block's slot.
        XCTAssertEqual(window.toolbar?.items.map(\.itemIdentifier),
                       [.flexibleSpace, .filesIdentical, .space, .toggleMinimap])

        // The badge reads as "Files are identical" to assistive tech.
        let root = try XCTUnwrap(window.contentView?.superview)
        XCTAssertNotNil(descendants(of: root).first { $0.accessibilityLabel() == "Files are identical" },
                        "the badge's accessibility label is 'Files are identical'")
    }

    /// Two different files keep the Prev/Next Difference block — the badge is
    /// for the no-differences case only, so it must not appear here.
    func testDifferentFilesKeepTheArrowsNotTheBadge() throws {
        let wc = makeWindow()
        let controller = wc.mainViewController
        let window = wc.window!
        let urlA = try tempFile([UInt8](repeating: 0x11, count: 64))
        let urlB = try tempFile([UInt8](repeating: 0x22, count: 64))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try controller.windowModel.pane1.open(url: urlA)
        try controller.windowModel.pane2.open(url: urlB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()

        XCTAssertTrue(pumpUntil(5) { has(window, .diffNavigation) && !has(window, .filesIdentical) },
                      "different files: the arrows stay, no badge")
    }

    /// Replacing a file in an already-open pane leaves the mode `.comparison`,
    /// so `refreshMode` skips `apply` and the comparison would never restart —
    /// the index kept the previous files' differences (phantom blocks in the
    /// overview and the arrows). Opening a new file replaces the storage
    /// wholesale, so it must invalidate the comparison the way a revert does.
    func testReplacingFilesInOpenPanesRebuildsTheComparison() throws {
        let wc = makeWindow()
        let controller = wc.mainViewController
        let window = wc.window!
        let diffA = try tempFile([UInt8](repeating: 0x11, count: 64))
        let diffB = try tempFile([UInt8](repeating: 0x22, count: 64))
        let sameA = try tempFile([UInt8](repeating: 0x33, count: 64))
        let sameB = try tempFile([UInt8](repeating: 0x33, count: 64))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: diffA)
            try? FileManager.default.removeItem(at: diffB)
            try? FileManager.default.removeItem(at: sameA)
            try? FileManager.default.removeItem(at: sameB)
        }

        // Two different files: the arrows show.
        try controller.windowModel.pane1.open(url: diffA)
        try controller.windowModel.pane2.open(url: diffB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(5) { has(window, .diffNavigation) },
                      "different files: the arrows appear")

        // Replace both with identical files the way File > Open does when both
        // panes are already open: the mode is unchanged, so no `apply` runs —
        // only each pane's own open fires. The index must rebuild from the new
        // files and the badge take the arrows' place.
        try controller.windowModel.pane1.open(url: sameA)
        try controller.windowModel.pane2.open(url: sameB)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(5) { has(window, .filesIdentical) && !has(window, .diffNavigation) },
                      "identical replacements: the badge replaces the stale arrows")
    }

    /// While a rebuild is in flight the comparison outcome is undetermined, and
    /// the plaque must keep its last DETERMINED state — not fall back to the
    /// arrows, which is what made the buttons flicker while typing, each edit
    /// re-running the comparison and dropping the plaque to the arrows for the
    /// build's whole duration. Here the last determined state is the badge
    /// (identical files); replacing both panes with different files starts a
    /// rebuild, and the badge must stay up until the new index lands and reports
    /// differences.
    ///
    /// The replacement files are large so the rebuild outlives a frame: the
    /// plaque is sampled only after the toolbar has had a run-loop turn to apply
    /// its decision, while the build is still running. A small file would finish
    /// before the first sample, and the test could not tell "kept the badge
    /// through the build" from "the build already landed the arrows".
    func testRebuildInFlightKeepsTheLastDeterminedPlaque() throws {
        let wc = makeWindow()
        let controller = wc.mainViewController
        let window = wc.window!
        // Identical, so the first build lands the badge.
        let sameA = try tempFile([UInt8](repeating: 0x11, count: 64))
        let sameB = try tempFile([UInt8](repeating: 0x11, count: 64))
        // Different and large, so the rebuild they trigger is in flight for more
        // than a frame (the scan is chunked at 1 MB; 64 MB is tens of chunks).
        let big = 64 * 1024 * 1024
        let diffA = try tempFile([UInt8](repeating: 0x22, count: big))
        let diffB = try tempFile([UInt8](repeating: 0x33, count: big))
        defer {
            controller.windowModel.pane1.close()
            controller.windowModel.pane2.close()
            wc.close()
            try? FileManager.default.removeItem(at: sameA)
            try? FileManager.default.removeItem(at: sameB)
            try? FileManager.default.removeItem(at: diffA)
            try? FileManager.default.removeItem(at: diffB)
        }

        try controller.windowModel.pane1.open(url: sameA)
        try controller.windowModel.pane2.open(url: sameB)
        controller.apply(mode: .comparison)
        window.layoutIfNeeded()
        XCTAssertTrue(pumpUntil(5) { has(window, .filesIdentical) && !has(window, .diffNavigation) },
                      "identical files: the badge shows")

        // Replace both with different files: a rebuild starts and the outcome is
        // undetermined until it lands.
        try controller.windowModel.pane1.open(url: diffA)
        try controller.windowModel.pane2.open(url: diffB)

        // Sample the plaque as the rebuild runs. Each turn spins a frame first,
        // so the toolbar has applied its decision for the in-flight build before
        // we read it; the badge must still be up while the build is running.
        var keptBadgeDuringBuild = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120.0))
            if has(window, .filesIdentical) && !has(window, .diffNavigation) {
                keptBadgeDuringBuild = true
            }
            if has(window, .diffNavigation) && !has(window, .filesIdentical) {
                break  // the new index landed: differences, the arrows take over
            }
        }
        XCTAssertTrue(keptBadgeDuringBuild,
                      "while the rebuild is in flight the plaque keeps the badge; "
                      + "it must not flicker back to the arrows")
        XCTAssertTrue(has(window, .diffNavigation) && !has(window, .filesIdentical),
                      "and once the rebuild lands the differences, the arrows take the badge's place")
    }
}
