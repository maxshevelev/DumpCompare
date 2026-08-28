import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §10.5 keyboard navigation. Cmd+arrow jumps the caret to row/file bounds
/// (row = 16 bytes); Fn+arrow scrolls the viewport without moving the caret.
/// Driven through the real `HexView.keyDown` with synthesized key events — the
/// modifier flags are set explicitly, since a test can't inject a real Fn press
/// (real-hardware Fn+arrow is a manual sanity check).
@MainActor
final class KeyboardNavigationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A single pane hosting a real hex view in a real window (same fixture as
    /// CaretPlacementTests), settled a few run-loop turns so the scroll view has
    /// a real viewport height (DiffNavigationTests' settling).
    private func makePane(_ bytes: [UInt8]) throws -> (PaneViewModel, HexView, NSWindow, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let filePane = FilePaneView(viewModel: pane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        filePane.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(filePane)
        NSLayoutConstraint.activate([
            filePane.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            filePane.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            filePane.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            filePane.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        for _ in 0..<4 {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            window.layoutIfNeeded()
        }
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        return (pane, hexView, window, url)
    }

    private func key(_ hexView: HexView, window: NSWindow, scalar: UInt32, _ flags: NSEvent.ModifierFlags) {
        let chars = String(UnicodeScalar(scalar)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: 0)!
        hexView.keyDown(with: event)
    }

    // MARK: - Cmd+arrow (caret to row/file bounds)

    func testCmdLeftMovesCaretToRowStart() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF702, [.command])   // Cmd+Left
        XCTAssertEqual(pane.caretOffset, 0)
    }

    /// A bare caret lands *on* the row's last byte (offset 15), not one past it
    /// (16 would be the next row's first byte) — the selection's half-open end
    /// sits at 16, the caret at the byte it covers (§10.5).
    func testCmdRightLandsCaretOnLastByteOfRow() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF703, [.command])   // Cmd+Right
        XCTAssertEqual(pane.caretOffset, 15)
    }

    /// On the last (partial) row the caret lands on the file's final byte (19),
    /// not one past it — `rowEnd - 1` clamped by the file size.
    func testCmdRightOnLastRowLandsOnLastByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 20))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 18, center: false)
        key(hexView, window: window, scalar: 0xF703, [.command])   // Cmd+Right
        XCTAssertEqual(pane.caretOffset, 19)
    }

    func testCmdUpMovesCaretToFileStart() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 30, center: false)
        key(hexView, window: window, scalar: 0xF700, [.command])   // Cmd+Up
        XCTAssertEqual(pane.caretOffset, 0)
    }

    func testCmdDownMovesCaretToFileEnd() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF701, [.command])   // Cmd+Down
        XCTAssertEqual(pane.caretOffset, 32)
    }

    func testCmdShiftRightExtendsSelection() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF703, [.command, .shift])   // Shift+Cmd+Right
        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexSelection().end, 16)
    }

    func testCmdLeftFromSelectionCollapsesToRowStart() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.select(range: 2..<7)
        key(hexView, window: window, scalar: 0xF702, [.command])   // Cmd+Left
        XCTAssertEqual(pane.caretOffset, 0)
        XCTAssertTrue(pane.hexSelection().isEmpty)
    }

    /// The scoped Cmd+arrow branch must not fire when Option is present — the
    /// View menu owns Cmd+Option(+Shift)+arrow for difference navigation
    /// (§10.3), so the keystroke defers to the menu and the caret is untouched.
    func testCmdOptionRightIsNotHandledHere() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF703, [.command, .option])   // Cmd+Option+Right
        XCTAssertEqual(pane.caretOffset, 5)
    }

    // MARK: - Reveal follows the selection's active edge (§10.4)

    /// With no selection the reveal offset is the caret itself.
    func testRevealOffsetIsCaretWhenBare() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        XCTAssertEqual(pane.hexCaretRevealOffset(), 5)
    }

    /// Extending forward (Shift+Right) keeps the anchor at the start, so the
    /// moving edge — and the reveal the viewport follows — is the selection's
    /// last byte, not its fixed start.
    func testRevealOffsetTracksForwardEdge() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF703, [.shift])   // Shift+Right → 5..<6
        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexSelection().end, 6)
        XCTAssertEqual(pane.hexCaretRevealOffset(), 5, "the last byte of a forward selection")
    }

    /// Extending backward (Shift+Left) keeps the anchor at the end, so the
    /// moving edge — and the reveal — is the selection's first byte.
    func testRevealOffsetTracksBackwardEdge() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        pane.moveCaret(to: 5, center: false)
        key(hexView, window: window, scalar: 0xF702, [.shift])   // Shift+Left → 4..<5
        XCTAssertEqual(pane.hexSelection().start, 4)
        XCTAssertEqual(pane.hexSelection().end, 5)
        XCTAssertEqual(pane.hexCaretRevealOffset(), 4, "the first byte of a backward selection")
    }

    /// A file tall enough that the viewport can scroll by more than one page.
    private let tallFile = [UInt8](repeating: 0x11, count: 4096)

    // MARK: - Centre the caret when an arrow finds it off-screen (§10.4)

    /// Scrolling the viewport away from the caret and then pressing an arrow
    /// brings the view back and *centres* the caret — a minimum scroll would
    /// only nudge it to the edge, not the middle.
    func testArrowCentresCaretWhenOffScreen() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        // Park the caret mid-file so a centre doesn't clamp to an edge.
        let mid = UInt64(tallFile.count / 2)
        pane.moveCaret(to: mid, center: false)
        hexView.scrollViewportToBottom()   // the caret's row is now off-screen
        key(hexView, window: window, scalar: 0xF701, [])   // Down → caret +1 row
        XCTAssertEqual(pane.caretOffset, mid + 16)
        let layout = hexView.hexLayout
        let (row, _) = layout.rowColumn(of: pane.caretOffset)
        let expected = min(max(0, layout.rowFrame(row: row).midY - clip.bounds.height / 2),
                           max(0, hexView.bounds.height - clip.bounds.height))
        XCTAssertEqual(clip.bounds.origin.y, expected, accuracy: 0.5, "the off-screen caret is centred")
    }

    /// The autoscroll case: the caret is on screen, so an arrow that pushes it
    /// toward an edge takes the minimum scroll — it does *not* centre (that
    /// would yank the view to the middle on every step).
    func testArrowDoesNotCentreWhenCaretOnScreen() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        pane.moveCaret(to: 0, center: false)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5, "starts at the top")
        key(hexView, window: window, scalar: 0xF701, [])   // Down → caret to row 1 (on screen)
        XCTAssertEqual(pane.caretOffset, 16)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5, "no centre-jump while the caret was on screen")
    }

    // MARK: - Fn+arrow (viewport, caret untouched)

    func testFnDownScrollsViewportByOnePage() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let layout = hexView.hexLayout
        let page = CGFloat(max(1, Int(clip.bounds.height / layout.rowHeight))) * layout.rowHeight
        let maxScroll = max(0, hexView.bounds.height - clip.bounds.height)
        XCTAssertGreaterThan(maxScroll, page, "the file must be taller than a page for this to mean anything")
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5, "starts at the top")
        key(hexView, window: window, scalar: 0xF72D, [.function])   // Fn+Down
        XCTAssertEqual(clip.bounds.origin.y, min(page, maxScroll), accuracy: 0.5, "Fn+Down scrolls one page")
        XCTAssertEqual(pane.caretOffset, 0, "the caret did not move")
    }

    func testFnUpReturnsToTop() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        key(hexView, window: window, scalar: 0xF72D, [.function])   // Fn+Down
        key(hexView, window: window, scalar: 0xF72C, [.function])   // Fn+Up
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5, "Fn+Up returns to the top")
        XCTAssertEqual(pane.caretOffset, 0, "the caret did not move")
    }

    func testFnRightScrollsToBottom() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let maxScroll = max(0, hexView.bounds.height - clip.bounds.height)
        key(hexView, window: window, scalar: 0xF72B, [.function])   // Fn+Right
        XCTAssertEqual(clip.bounds.origin.y, maxScroll, accuracy: 0.5, "Fn+Right scrolls to the bottom")
        XCTAssertEqual(pane.caretOffset, 0, "the caret did not move")
    }

    func testFnLeftScrollsToTop() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        key(hexView, window: window, scalar: 0xF72B, [.function])   // Fn+Right (to the bottom)
        key(hexView, window: window, scalar: 0xF729, [.function])   // Fn+Left (back to the top)
        XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5, "Fn+Left scrolls to the top")
    }

    /// A physical PageDown (no `.function`) still moves the caret — by one
    /// viewport height now that `pageStep` reads the clip view, not the document.
    /// Guards that the `.function` branch didn't steal the physical key.
    func testPhysicalPageDownStillMovesCaret() throws {
        let (pane, hexView, window, url) = try makePane(tallFile)
        defer { pane.close(); try? FileManager.default.removeItem(at: url) }
        let clip = try XCTUnwrap(hexView.enclosingScrollView).contentView
        let layout = hexView.hexLayout
        let page = max(1, Int(clip.bounds.height / layout.rowHeight)) * HexLayout.bytesPerRow
        pane.moveCaret(to: 0, center: false)
        key(hexView, window: window, scalar: 0xF72D, [])   // physical PageDown
        XCTAssertEqual(pane.caretOffset, UInt64(page), "physical PageDown moves the caret by one page")
    }
}
