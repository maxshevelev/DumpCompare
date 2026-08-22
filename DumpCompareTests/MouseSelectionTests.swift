import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Drag-selection tests through the real `HexView` (§6): a byte joins the
/// selection when the pointer passes its cell-centre, not when it enters the
/// next byte's zone — so the row's last byte is selectable by dragging.
///
/// Events are synthesized and delivered straight to the hex view (same pattern
/// as `HeaderFitWidthTests`), so the full path — point → `dragEndOffset` →
/// `didClickAt` → `PaneViewModel` selection — is exercised.
@MainActor
final class MouseSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// A pane hosting a real hex view in a real window. The temp file stays on
    /// disk (the pane reads it lazily) and the caller removes it when done.
    private func makePane(_ bytes: [UInt8]) throws -> (FilePaneView, PaneViewModel, HexView, NSWindow, URL) {
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
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        return (filePane, pane, hexView, window, url)
    }

    /// Window point of the centre of byte `column` in `row` — the boundary at
    /// which a byte joins a drag selection.
    private func byteCentre(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    /// Window point `dx` px right of byte `column`'s nibble boundary (the byte's
    /// centre). `dx == 0` is the gap between the two nibble characters; a
    /// `|dx|` up to `charWidth / 2` stays inside the byte's dead zone (§3.3).
    private func pointInByte(_ hexView: HexView, row: Int, column: Int, dx: CGFloat) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth + dx,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    private func drag(_ hexView: HexView, window: NSWindow,
                      from start: (row: Int, column: Int), to end: (row: Int, column: Int)) {
        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: start.row, column: start.column), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: byteCentre(hexView, row: end.row, column: end.column), window: window))
    }

    func testDragRightSelectsThroughByteUnderPointer() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 0), to: (0, 5))
        XCTAssertEqual(pane.hexSelection().start, 0)
        XCTAssertEqual(pane.hexSelection().end, 6,
                       "bytes 0…5: byte 5 joined when the pointer passed its centre")

        // The same rule across a row boundary, and from an anchor that is not
        // the row's first byte — the anchor is just where mouseDown landed.
        drag(hexView, window: window, from: (0, 0), to: (1, 3))
        XCTAssertEqual(pane.hexSelection().end, 20, "row 0 (16 bytes) plus bytes 16…19")

        drag(hexView, window: window, from: (0, 3), to: (0, 5))
        XCTAssertEqual(pane.hexSelection().start, 3, "the anchor is the byte the drag started on")
        XCTAssertEqual(pane.hexSelection().end, 6)
    }

    func testDragSelectsLastByteOfRow() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 0), to: (0, 15))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 16)  // the row's last byte needs no next byte
    }

    func testDragPastEndClampsToFileSize() throws {
        // 20-byte file: one full row + 4 bytes on row 1.
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 20))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 0), to: (1, 15))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 20)  // clamped to EOF
    }

    /// A plain click still places the caret exactly on the clicked byte — the
    /// centre rule applies only to extending (drag / shift-click).
    func testPlainClickPlacesCaretExactly() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 5), window: window))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 5)
        XCTAssertEqual(sel.end, 5)
    }

    // MARK: - Dead zone (§3.3)

    /// A click between a byte's nibbles places the mid-byte caret; a drag that
    /// stays inside the byte's dead zone — from the middle of the high-nibble
    /// character to the middle of the low-nibble one — is mouse jitter, not a
    /// selection. The old behaviour selected the byte on a 1 px move, because
    /// the drag boundary sat exactly on the byte's centre.
    func testJitterInDeadZoneDoesNotSelect() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        // Click on byte 0's nibble boundary, drag a quarter of a character right
        // — well inside the dead zone (charWidth / 2 on either side of the gap).
        let jitter = hexView.hexLayout.charWidth * 0.25
        hexView.mouseDown(with: mouse(.leftMouseDown, at: pointInByte(hexView, row: 0, column: 0, dx: 0), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: pointInByte(hexView, row: 0, column: 0, dx: jitter), window: window))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 0, "jitter inside the dead zone must not select the byte")
        XCTAssertEqual(pane.hexCaretNibble(), 1, "the mid-byte caret is kept")
    }

    /// A drag that leaves the dead zone selects from the click byte onward.
    func testDragOutOfDeadZoneSelectsFromClick() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        hexView.mouseDown(with: mouse(.leftMouseDown, at: pointInByte(hexView, row: 0, column: 0, dx: 0), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: byteCentre(hexView, row: 0, column: 2), window: window))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 3, "bytes 0…2 are selected once the drag leaves the dead zone")
    }

    /// Dragging left from a mid-byte caret selects the byte before it.
    func testDragLeftFromNibbleGapSelectsPreviousByte() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        hexView.mouseDown(with: mouse(.leftMouseDown, at: pointInByte(hexView, row: 0, column: 2, dx: 0), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: pointInByte(hexView, row: 0, column: 1, dx: -1), window: window))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 1)
        XCTAssertEqual(sel.end, 2, "byte 1 is selected by dragging left past its centre")
    }
}
