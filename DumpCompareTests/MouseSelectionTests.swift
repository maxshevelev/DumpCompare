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

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mouse-sel-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
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

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Window point of the centre of byte `column` in `row` — the boundary at
    /// which a byte joins a drag selection.
    private func byteCentre(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
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

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 6)   // bytes 0…5; byte 5 joined at its centre
    }

    func testDragSelectsLastByteOfRow() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 0), to: (0, 15))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 16)  // the row's last byte needs no next byte
    }

    func testDragAcrossRowsSelectsThroughSecondRow() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 0), to: (1, 3))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 0)
        XCTAssertEqual(sel.end, 20)  // row 0 (16) + bytes 16…19
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

    func testDragFromMiddleAnchor() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        drag(hexView, window: window, from: (0, 3), to: (0, 5))

        let sel = pane.hexSelection()
        XCTAssertEqual(sel.start, 3)
        XCTAssertEqual(sel.end, 6)
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
}
