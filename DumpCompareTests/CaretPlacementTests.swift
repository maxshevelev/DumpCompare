import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3 caret placement: a click on a byte's low nibble places the caret
/// between the byte's two hex characters, a click on the high nibble before
/// them. Arrow navigation is byte-wise — it always lands on a byte's left
/// boundary (nibble 0), even when the caret was mid-byte.
///
/// Driven through the real `HexView` with synthesized mouse and key events (same
/// pattern as `MouseSelectionTests`), so the full path — point → `hitTest` →
/// `didClickAt` nibble → `PaneViewModel` — is exercised.
@MainActor
final class CaretPlacementTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caret-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A single pane hosting a real hex view in a real window.
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
        let hexView = try XCTUnwrap(filePane.scrollView.documentView as? HexView)
        return (pane, hexView, window, url)
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Centre of the byte's `nibble`th hex character (0 = high, 1 = low).
    private func nibblePoint(_ hexView: HexView, row: Int, column: Int, nibble: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth * (CGFloat(nibble) + 0.5),
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    /// Centre of the ASCII character for `column`.
    private func asciiPoint(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.asciiX(column: column) + layout.charWidth / 2,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    private func click(_ hexView: HexView, at p: NSPoint, window: NSWindow) {
        hexView.mouseDown(with: mouse(.leftMouseDown, at: p, window: window))
    }

    private func arrowKey(_ hexView: HexView, window: NSWindow, scalar: UInt32) {
        let chars = String(UnicodeScalar(scalar)!)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: 0)!
        hexView.keyDown(with: event)
    }

    func testClickHighNibblePlacesCaretBeforeFirstChar() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 0), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    func testClickLowNibblePlacesCaretMidByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 1), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 1)
    }

    /// Typing from a mid-byte caret edits the low nibble first, then advances
    /// to the next byte — the existing typing semantics, reachable now by click.
    func testTypingFromMidByteEditsLowNibble() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 0, nibble: 1), window: window)
        pane.typeHexNibble(0xA)

        // High nibble 0x1 kept, low nibble replaced: 0x11 → 0x1A; the completed
        // byte advances the caret to the next byte's left boundary.
        XCTAssertEqual(try pane.byteStorage?.read(at: 0, length: 1), [0x1A])
        XCTAssertEqual(pane.hexSelection().start, 1)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    /// Arrow navigation is byte-wise: from a mid-byte caret, Left lands on the
    /// previous byte's left boundary and Right on the next byte's, both at
    /// nibble 0.
    func testArrowsMoveByteWiseFromMidByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        // Place the caret mid-byte 5.
        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 1), window: window)
        XCTAssertEqual(pane.hexCaretNibble(), 1)

        // Right: next byte's left boundary.
        arrowKey(hexView, window: window, scalar: 0xF703)
        XCTAssertEqual(pane.hexSelection().start, 6)
        XCTAssertEqual(pane.hexCaretNibble(), 0)

        // Left (from 6): back to byte 5's left boundary.
        arrowKey(hexView, window: window, scalar: 0xF702)
        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 0)

        // Left again: byte 4.
        arrowKey(hexView, window: window, scalar: 0xF702)
        XCTAssertEqual(pane.hexSelection().start, 4)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    /// Clicking the ASCII area moves the caret there and resets any mid-byte
    /// nibble.
    func testAsciiClickResetsNibble() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 1), window: window)
        XCTAssertEqual(pane.hexCaretNibble(), 1)

        click(hexView, at: asciiPoint(hexView, row: 0, column: 5), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
        XCTAssertEqual(pane.hexInputRegion(), .ascii)
    }
}
