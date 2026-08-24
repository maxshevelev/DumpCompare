import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.3 the segment commands, exercised through the real `MainViewController`:
/// Split Here (the offset context menu's path, which opens the Add Cut popover
/// pre-filled with the right-clicked offset), the Add Cut… / Merge menu
/// validation, and the status bar's readout of the caret's piece.
///
/// Split Here is the way a cut normally gets made — the offset is the thing
/// that was right-clicked, so the popover opens pre-filled with it. The menu
/// items are built by `makeOffsetMenu`, which stamps the pane and offset onto
/// each item's `representedObject`; invoking the item drives the command on that
/// pane, not the active one.
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
    /// active-pane-based menu validation (Add Cut…, Merge) reads.
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

    /// Invokes `splitHere` on `item` with a capturing presenter, returning the
    /// request the command presented. A real popover anchored in a window that is
    /// never on screen closes the instant it opens, so the tests capture the
    /// request instead — the command's own behaviour is what is under test.
    private func capturedSplitRequest(_ controller: MainViewController, _ item: NSMenuItem) throws
        -> MainViewController.CutEditRequest {
        var captured: MainViewController.CutEditRequest?
        controller.cutEditPresenter = { captured = $0 }
        controller.splitHere(item)
        controller.cutEditPresenter = nil
        return try XCTUnwrap(captured, "Split Here must present the cut popover")
    }

    // MARK: - Split Here

    /// Right-clicking a byte opens the Add Cut popover pre-filled with that
    /// byte's own offset — the cut would land mid-row, between the byte to its
    /// left and the one to its right.
    func testSplitHereOpensThePopoverPrefilledWithTheClickedByte() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let item = try splitItem(for: pane, offset: 5)
        let request = try capturedSplitRequest(MainViewController(), item)

        XCTAssertEqual(request.prefillOffset, 5, "the popover starts at the clicked byte")
        XCTAssertTrue(request.pane === pane, "the popover is for the right-clicked pane")
        XCTAssertTrue(request.anchoredToOffset,
                      "Split Here hangs off the byte it was invoked on")
        // Committing the pre-filled offset makes the cut at that byte.
        request.commit(5, "")
        XCTAssertEqual(pane.segmentStore.cuts, [5], "committing the prefill cuts at the clicked byte")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<5, 5..<32])
    }

    /// Add Cut… presents the same popover but centred in the pane, not anchored
    /// to the caret (§21.3): the offset is still pre-filled with the caret's, but
    /// the request is not anchored to an offset.
    func testAddCutPresentsACentredPopover() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.setSelection(SelectionModel.empty(at: 5, fileSize: 16))

        var captured: MainViewController.CutEditRequest?
        controller.cutEditPresenter = { captured = $0 }
        controller.addCut()
        controller.cutEditPresenter = nil

        let request = try XCTUnwrap(captured, "Add Cut… must present the cut popover")
        XCTAssertFalse(request.anchoredToOffset,
                       "Add Cut… centres the popover instead of anchoring it to the caret")
        XCTAssertEqual(request.prefillOffset, 5, "the offset is still pre-filled with the caret's")
        XCTAssertTrue(request.pane === pane, "the popover is for the active pane")
        _ = window
    }

    /// Right-clicking an address opens the popover pre-filled with the row's
    /// start — the offset the address names, not a byte within the row.
    func testSplitHereOpensThePopoverPrefilledWithTheClickedAddress() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }

        // Row 1's address is 0x10, its start offset.
        let item = try splitItem(for: pane, offset: 0x10)
        let request = try capturedSplitRequest(MainViewController(), item)

        XCTAssertEqual(request.prefillOffset, 0x10, "the popover starts at the clicked address")
        request.commit(0x10, "")
        XCTAssertEqual(pane.segmentStore.cuts, [0x10], "committing the prefill cuts at the clicked address")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<0x10, 0x10..<48])
    }

    /// Split Here acts on the pane the menu was built for, not the active one —
    /// a fresh controller's active pane has no document, so a fallback to it
    /// would present a popover for the wrong pane.
    func testSplitHereActsOnTheRightClickedPane() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = MainViewController()  // active pane is empty
        let item = try splitItem(for: pane, offset: 8)
        let request = try capturedSplitRequest(controller, item)

        XCTAssertTrue(request.pane === pane, "the popover is for the right-clicked pane, not the active one")
        XCTAssertEqual(request.prefillOffset, 8)
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

    /// Merge is disabled while the pane is a single piece — there is
    /// no neighbour to merge into — and enabled for every piece once the dump is
    /// partitioned, including S0 (merging it reopens the piece below at the
    /// file start).
    func testRemoveSegmentIsEnabledOnEveryPieceOncePartitioned() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        let item = NSMenuItem(title: "Merge", action: #selector(MainViewController.removeSegment(_:)), keyEquivalent: "")

        // No cuts yet: one piece, nothing to merge into, so the command is off.
        XCTAssertFalse(controller.validateMenuItem(item), "a single piece has no neighbour to merge into")

        // A cut at 8: two pieces. The caret in the first piece (S0) is now
        // mergeable — merging it reopens the piece below at the file start.
        pane.segmentStore.addCut(at: 8)
        pane.setSelection(SelectionModel.empty(at: 4, fileSize: 16))
        XCTAssertTrue(controller.validateMenuItem(item), "S0 is mergeable once the dump is partitioned")
        XCTAssertEqual(item.title, "Merge S0 into S1",
                       "the item names the piece and its neighbour, not a bare 'Merge'")

        // The caret in the second piece (S1): also mergeable, into S0.
        pane.setSelection(SelectionModel.empty(at: 12, fileSize: 16))
        XCTAssertTrue(controller.validateMenuItem(item), "a later piece is mergeable too")
        XCTAssertEqual(item.title, "Merge S1 into S0",
                       "moving the caret renames the item to the piece it will now merge")
        _ = window
    }

    /// The offset context menu's Merge names the piece the right-clicked
    /// byte is in — the same naming as the Edit menu's item, but resolved from the
    /// byte that was clicked rather than the caret (§21.3).
    func testTheOffsetMenusRemoveSegmentNamesTheClickedPiecesPiece() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.segmentStore.addCut(at: 8)   // S0 = [0,8), S1 = [8,16)
        let controller = MainViewController()

        func removeItem(at offset: UInt64) throws -> NSMenuItem {
            let menu = controller.makeOffsetMenu(for: pane, offset: offset)
            return try XCTUnwrap(
                menu.items.first { $0.action == #selector(MainViewController.removeSegment(_:)) },
                "the offset menu must offer Merge")
        }

        // A byte in S1 names S1, merging into S0.
        let inS1 = try removeItem(at: 12)
        XCTAssertTrue(controller.validateMenuItem(inS1), "S1 has a neighbour, so it is mergeable")
        XCTAssertEqual(inS1.title, "Merge S1 into S0",
                       "the item names the piece the right-clicked byte is in")

        // A byte in S0 names S0, merging into S1.
        let inS0 = try removeItem(at: 4)
        XCTAssertTrue(controller.validateMenuItem(inS0))
        XCTAssertEqual(inS0.title, "Merge S0 into S1")
    }

    /// Split Here is offered whenever the pane has bytes — the offset is NOT
    /// pre-validated by the menu item. The bounds (0 and EOF) and a seam another
    /// cut already holds are all offered, because the refusal happens in the
    /// popover, which checks the offset as it is typed (red field, a beep on
    /// Return) — the same as Add Cut…: the menu opens the popover, the popover
    /// does the checking (§21.3).
    func testSplitHereIsOfferedWheneverAFileIsOpen() throws {
        let (pane, url) = try makePane([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = MainViewController()

        func valid(_ offset: UInt64) -> Bool {
            let item = try! splitItem(for: pane, offset: offset)
            return controller.validateMenuItem(item)
        }

        XCTAssertTrue(valid(0), "the file start is offered; the popover refuses it")
        XCTAssertTrue(valid(16), "EOF is offered; the popover refuses it")
        XCTAssertTrue(valid(8), "a cut strictly inside the file is offered")

        pane.segmentStore.addCut(at: 8)
        XCTAssertTrue(valid(8), "a seam another cut holds is offered; the popover refuses it")
    }

    // MARK: - Merge

    /// Merge merges the caret's piece into the one above it — dropping
    /// the cut at the piece's start — leaving the bytes untouched.
    func testRemoveSegmentMergesTheCaretPieceWithTheOneAbove() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        _ = window

        pane.segmentStore.addCut(at: 4)
        pane.segmentStore.addCut(at: 8)
        // Three pieces: [0,4) [4,8) [8,16). The caret in the middle piece.
        pane.setSelection(SelectionModel.empty(at: 6, fileSize: 16))

        controller.removeSegment(nil)

        // The cut at 4 (the middle piece's start) is gone; the cut at 8 remains.
        XCTAssertEqual(pane.segmentStore.cuts, [8], "the caret's piece merges with the one above it")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<8, 8..<16])
    }

    /// Removing S0 is supported once the dump is partitioned: the piece below
    /// reopens at the file start and takes S0's place, keeping its own name.
    func testRemoveSegmentOnS0PromotesThePieceBelow() throws {
        let (controller, window, url) = try makeController([UInt8](repeating: 0x11, count: 16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        _ = window

        pane.segmentStore.addCut(at: 8)
        pane.segmentStore.rename(1, to: "second")
        // The caret in S0.
        pane.setSelection(SelectionModel.empty(at: 4, fileSize: 16))

        controller.removeSegment(nil)

        // S0 is gone; what was S1 reopens at 0 and is now S0, keeping its name.
        XCTAssertEqual(pane.segmentStore.cuts, [], "S0 removed, the file is one piece again")
        XCTAssertEqual(pane.segmentStore.segments.map(\.range), [0..<16])
        XCTAssertEqual(pane.segmentStore.segments.first?.name, "second", "the promoted piece keeps its name")
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

    /// §21.3 the status bar's format: the caret's offset and the piece's bounds
    /// are bare hex (no `0x` prefix, no decimal), zero-padded to the width of
    /// the file's largest address, and the piece is one block
    /// `S1: <start>-<end> (length)`.
    func testTheStatusBarRendersBareHexAndOneSegmentBlock() throws {
        let url = try tempFile([UInt8](repeating: 0x11, count: 16))
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        viewModel.segmentStore.addCut(at: 8)
        // The caret at 12 (0xC), in the second piece.
        viewModel.setSelection(SelectionModel.empty(at: 12, fileSize: 16))

        let view = FilePaneView(viewModel: viewModel)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.layoutSubtreeIfNeeded()

        // The file's largest address is 0x10 (its size), two hex digits, so every
        // address is padded to two: caret 0xC → "0C", S1 = [8, 16) → "08-10".
        XCTAssertEqual(view.statusLabel.stringValue,
                       "Offset 0C  ·  S1: 08-10 (8 B)  ·  16 B")
    }

    /// §21.3 the padding width follows the file's largest address, and the
    /// piece's length is a whole value of its abbreviation: a 4 MB file whose
    /// last piece ends at 0x400000 pads every address to six digits and shows
    /// the piece's length rounded, not to a decimal.
    func testTheStatusBarPadsToTheFilesLargestAddressAndRoundsTheLength() throws {
        let size: UInt64 = 0x400000   // 4 MB, six hex digits
        let url = try tempFile([UInt8](repeating: 0x11, count: Int(size)))
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = PaneViewModel()
        try viewModel.open(url: url)
        // A cut at 0x2E6: S1 = [0x2E6, 0x400000), length 0x400000 - 0x2E6.
        viewModel.segmentStore.addCut(at: 0x2E6)
        viewModel.setSelection(SelectionModel.empty(at: 0x2E6, fileSize: size))

        let view = FilePaneView(viewModel: viewModel)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.layoutSubtreeIfNeeded()

        // 0x400000 - 0x2E6 = 4193562 B = 3.999 MB → "4 MB"; the file is "4 MB".
        XCTAssertEqual(view.statusLabel.stringValue,
                       "Offset 0002E6  ·  S1: 0002E6-400000 (4 MB)  ·  4 MB")
    }
}
