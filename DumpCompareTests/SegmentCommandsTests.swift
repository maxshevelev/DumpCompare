import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.3 the cut commands, exercised through the real `MainViewController`:
/// Split Here (the offset context menu's no-dialog path), the Add Cut… / Remove
/// Cut menu validation, and the status bar's readout of the caret's piece.
///
/// Split Here is the way a cut normally gets made — the offset is the thing
/// that was right-clicked, so there is nothing to type. The menu items are
/// built by `makeOffsetMenu`, which stamps the pane and offset onto each item's
/// `representedObject`; invoking the item drives the command on that pane, not
/// the active one.
@MainActor
final class SegmentCommandsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A pane over a real temp file, open and ready to take cuts. The caller
    /// removes the file when done.
    private func makePane(_ bytes: [UInt8]) throws -> (PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        return (pane, url)
    }

    /// A full controller whose active pane is open — the setup the
    /// active-pane-based menu validation (Add Cut…, Remove Cut) reads.
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// The "Split Here" item of the offset menu for `pane` at `offset`.
    private func splitItem(for pane: PaneViewModel, offset: UInt64) throws -> NSMenuItem {
        let menu = MainViewController().makeOffsetMenu(for: pane, offset: offset)
        return try XCTUnwrap(menu.items.first { $0.title == "Split Here" },
                             "the offset menu must offer Split Here")
    }

    // MARK: - Split Here

    /// Right-clicking a byte splits at that byte's own offset — the cut lands
    /// mid-row, between the byte to its left and the one to its right.
    func testSplitHereCutsAtTheClickedByte() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let item = try splitItem(for: pane, offset: 5)
        MainViewController().splitHere(item)

        XCTAssertEqual(pane.segmentStore.cuts, [5], "the cut is at the clicked byte")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<5, 5..<32])
    }

    /// Right-clicking an address splits at the row's start — the offset the
    /// address names, not a byte within the row.
    func testSplitHereCutsAtTheClickedAddress() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }

        // Row 1's address is 0x10, its start offset.
        let item = try splitItem(for: pane, offset: 0x10)
        MainViewController().splitHere(item)

        XCTAssertEqual(pane.segmentStore.cuts, [0x10], "the cut is at the clicked address")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<0x10, 0x10..<48])
    }

    /// Split Here acts on the pane the menu was built for, not the active one —
    /// a fresh controller's active pane has no document, so a fallback to it
    /// would make no cut at all.
    func testSplitHereActsOnTheRightClickedPane() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = MainViewController()  // active pane is empty
        let item = try splitItem(for: pane, offset: 8)
        controller.splitHere(item)

        XCTAssertEqual(pane.segmentStore.cuts, [8], "the cut lands on the right-clicked pane")
    }

    // MARK: - Menu validation

    /// Add Cut… needs bytes to split: an empty pane has none, so the item is
    /// disabled there and enabled once a file is open.
    func testAddCutRequiresAnOpenPane() throws {
        let item = NSMenuItem(title: "Add Cut…", action: #selector(MainViewController.addCut), keyEquivalent: "")

        let emptyController = MainViewController()
        XCTAssertFalse(emptyController.validateMenuItem(item), "no file, no cut")

        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        XCTAssertTrue(controller.validateMenuItem(item), "an open pane offers Add Cut…")
        _ = window
    }

    /// Remove Cut is disabled while the caret is in the first piece — there is
    /// no cut above it to remove — and enabled once the caret is in a later
    /// piece.
    func testRemoveCutIsDisabledOnTheFirstPiece() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        let item = NSMenuItem(title: "Remove Cut", action: #selector(MainViewController.removeCut), keyEquivalent: "")

        // No cuts yet: one piece, the caret in it, nothing to remove.
        XCTAssertFalse(controller.validateMenuItem(item), "a single piece has no cut above it")

        // A cut at 8: the caret in the first piece still has nothing above it.
        pane.segmentStore.addCut(at: 8)
        pane.setSelection(SelectionModel.empty(at: 4, fileSize: 16))
        XCTAssertFalse(controller.validateMenuItem(item), "the first piece has no cut above it")

        // The caret in the second piece: the cut at 8 is above it and removable.
        pane.setSelection(SelectionModel.empty(at: 12, fileSize: 16))
        XCTAssertTrue(controller.validateMenuItem(item), "a later piece has a cut above it")
        _ = window
    }

    /// Split Here is disabled at the bounds (0 and EOF) and on a seam another
    /// cut already holds — every piece must stay non-empty.
    func testSplitHereIsDisabledAtTheBoundsAndOnExistingCuts() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainViewController()

        func valid(_ offset: UInt64) -> Bool {
            let item = try! splitItem(for: pane, offset: offset)
            return controller.validateMenuItem(item)
        }

        XCTAssertFalse(valid(0), "a cut at the file start is refused")
        XCTAssertFalse(valid(16), "a cut at EOF is refused")
        XCTAssertTrue(valid(8), "a cut strictly inside the file is offered")

        pane.segmentStore.addCut(at: 8)
        XCTAssertFalse(valid(8), "a seam another cut holds is refused")
    }

    // MARK: - Remove Cut

    /// Remove Cut merges the caret's piece with the one above it — the cut at
    /// the piece's start — leaving the bytes untouched.
    func testRemoveCutRemovesTheCaretPiecesUpperCut() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        _ = window

        pane.segmentStore.addCut(at: 4)
        pane.segmentStore.addCut(at: 8)
        // Three pieces: [0,4) [4,8) [8,16). The caret in the middle piece.
        pane.setSelection(SelectionModel.empty(at: 6, fileSize: 16))

        controller.removeCut()

        // The cut at 4 (the middle piece's start) is gone; the cut at 8 remains.
        XCTAssertEqual(pane.segmentStore.cuts, [8], "the caret's piece merges with the one above it")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<8, 8..<16])
    }

    // MARK: - The status bar readout

    /// With a cut, the status bar names the piece the caret is in — its label
    /// and range. The caret in the first piece reads S0, in the second S1.
    func testTheStatusBarNamesTheCaretsPiece() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.segmentStore.addCut(at: 8)

        pane.setSelection(SelectionModel.empty(at: 4, fileSize: 16))
        XCTAssertEqual(pane.status.segment?.label, "S0")
        XCTAssertEqual(pane.status.segment?.range, 0..<8)

        pane.setSelection(SelectionModel.empty(at: 12, fileSize: 16))
        XCTAssertEqual(pane.status.segment?.label, "S1")
        XCTAssertEqual(pane.status.segment?.range, 8..<16)
    }

    /// A single piece is the silence: with no cuts the readout is nil, so the
    /// readout's appearing at all is the signal that the dump is partitioned.
    func testTheStatusBarIsSilentWithOnePiece() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(pane.status.segment, "no cuts, no readout")

        // A cut makes the readout appear; removing it brings the silence back.
        pane.segmentStore.addCut(at: 8)
        XCTAssertNotNil(pane.status.segment)
        pane.segmentStore.removeCut(at: 8)
        XCTAssertNil(pane.status.segment, "back to one piece, the readout is gone")
    }
}
