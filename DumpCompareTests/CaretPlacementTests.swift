import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3 caret placement: a click in the second half of a byte's high-nibble
/// character — or anywhere on its low-nibble character — places the caret
/// between the byte's two hex characters; a click in the first half of the
/// high-nibble character places it before them. Arrow navigation is byte-wise —
/// it always lands on a byte's left boundary (nibble 0), even when the caret
/// was mid-byte.
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

    /// Click point inside the byte's hex cell. Nibble 0 is the first half of
    /// the high-nibble character (caret before the byte); nibble 1 is the
    /// second half of that character (caret between the two chars) — the
    /// threshold the user asked for: the mid-byte caret is placed from the
    /// second half of the first character onward.
    private func nibblePoint(_ hexView: HexView, row: Int, column: Int, nibble: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let fraction = nibble == 0 ? 0.25 : 0.75
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth * fraction,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    /// Centre of the byte's low-nibble (second) character.
    private func secondCharPoint(_ hexView: HexView, row: Int, column: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth * 1.5,
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

    /// A click in the first half of the byte's high-nibble character places
    /// the caret before the byte.
    func testClickFirstHalfOfHighNibblePlacesCaretBeforeByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 0), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 0)
    }

    /// A click in the second half of the byte's high-nibble character places
    /// the caret between the two chars — a large target for the mid-byte caret.
    func testClickSecondHalfOfHighNibblePlacesCaretMidByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 1), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 1)
    }

    /// Clicking the byte's low-nibble (second) character also places the caret
    /// between the chars — the pre-existing behavior is preserved.
    func testClickSecondCharPlacesCaretMidByte() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: secondCharPoint(hexView, row: 0, column: 5), window: window)

        XCTAssertEqual(pane.hexSelection().start, 5)
        XCTAssertEqual(pane.hexCaretNibble(), 1)
    }

    // MARK: - Hex ⇄ ASCII cross-link (§3.3)

    /// On the active pane a hex caret outlines the byte's ASCII char with the
    /// same rounded contour the mirrors use, linking the two columns of the
    /// same byte (§3.3). The ASCII column packs its chars, so a mid-column
    /// byte sits flush on both sides.
    func testActivePaneHexCaretFramesAsciiChar() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: nibblePoint(hexView, row: 0, column: 5, nibble: 0), window: window)
        XCTAssertEqual(pane.hexInputRegion(), .hex)

        let contour = hexView.crossLinkContour()
        XCTAssertEqual(contour.count, 4)
        let layout = hexView.hexLayout
        XCTAssertEqual(contour, [
            CGPoint(x: layout.asciiX(column: 5), y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 5) + layout.charWidth, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.asciiX(column: 5) + layout.charWidth, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.asciiX(column: 5), y: layout.rowFrame(row: 0).maxY),
        ])

        // The active pane draws no whole-byte pane mirror.
        XCTAssertTrue(hexView.mirrorContours().isEmpty)
    }

    /// On the active pane an ASCII caret outlines the byte's hex cell as a
    /// padded contour — word size 1 makes both edges word boundaries.
    func testActivePaneAsciiCaretFramesHexCell() throws {
        let (pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        click(hexView, at: asciiPoint(hexView, row: 0, column: 5), window: window)
        XCTAssertEqual(pane.hexInputRegion(), .ascii)

        let contour = hexView.crossLinkContour()
        XCTAssertEqual(contour.count, 4)
        let layout = hexView.hexLayout
        let pad = HexView.mirrorContourPadding
        XCTAssertEqual(contour, [
            CGPoint(x: layout.hexByteX(column: 5) - pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 5) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).minY),
            CGPoint(x: layout.hexByteX(column: 5) + layout.hexByteWidth + pad, y: layout.rowFrame(row: 0).maxY),
            CGPoint(x: layout.hexByteX(column: 5) - pad, y: layout.rowFrame(row: 0).maxY),
        ])
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

    // MARK: - Insert-mode caret rendering

    /// A real `HexView` backed by a real `PaneViewModel`, rendered straight to a
    /// bitmap (no window/scroll view), so the test measures the hex view's own
    /// drawing. Aqua appearance pins the dynamic colours (label → black, accent
    /// → blue, systemRed → red) for deterministic sampling.
    private func makeHexView(_ bytes: [UInt8]) throws -> (HexView, PaneViewModel, URL) {
        let url = try tempFile(bytes)
        let pane = PaneViewModel()
        try pane.open(url: url)
        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)
        hexView.dataSource = pane
        hexView.delegate = pane
        hexView.reloadData()
        return (hexView, pane, url)
    }

    /// Snapshots the view via `cacheDisplay`, which drives the real flipped
    /// `draw(_:)` path onto a bitmap at the backing scale.
    private func render(_ view: HexView) -> NSBitmapImageRep {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("no bitmap rep")
            return NSBitmapImageRep()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The strongest redness (red − blue) across a horizontal window of the
    /// rendering — the insert caret's giveaway.
    private func redness(_ hexView: HexView, y: CGFloat, x: CGFloat, width: CGFloat) throws -> CGFloat {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let py = min(max(Int(y * scale), 0), rep.pixelsHigh - 1)
        let first = max(0, Int((x * scale).rounded(.down)))
        let last = min(rep.pixelsWide - 1, Int(((x + width) * scale).rounded(.up)))
        guard last >= first else { return 0 }
        return (first...last).compactMap { rep.colorAt(x: $0, y: py)?.usingColorSpace(.deviceRGB) }
            .map { $0.redComponent - $0.blueComponent }
            .max() ?? 0
    }

    /// The strongest blueness (blue − red) across a horizontal window — the
    /// overwrite caret's giveaway.
    private func blueness(_ hexView: HexView, y: CGFloat, x: CGFloat, width: CGFloat) throws -> CGFloat {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let py = min(max(Int(y * scale), 0), rep.pixelsHigh - 1)
        let first = max(0, Int((x * scale).rounded(.down)))
        let last = min(rep.pixelsWide - 1, Int(((x + width) * scale).rounded(.up)))
        guard last >= first else { return 0 }
        return (first...last).compactMap { rep.colorAt(x: $0, y: py)?.usingColorSpace(.deviceRGB) }
            .map { $0.blueComponent - $0.redComponent }
            .max() ?? 0
    }

    /// The strongest "ink" (1 − min(r, g, b)) inside a point-space rect — how
    /// far the most-coloured pixel is from the paper, regardless of hue. A dim
    /// gray `_` placeholder reads ≈ 0.35; a filled digit reads well past 0.5
    /// whether it is black or the red of a modified byte — so this separates
    /// "empty slot" from "filled slot" without depending on the digit's colour.
    private func maxInk(_ hexView: HexView, in pointRect: NSRect) throws -> CGFloat {
        let rep = render(hexView)
        let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
        let startX = max(0, Int(floor(pointRect.minX * scale)))
        let endX = min(rep.pixelsWide - 1, Int(ceil(pointRect.maxX * scale)))
        let startY = max(0, Int(floor(pointRect.minY * scale)))
        let endY = min(rep.pixelsHigh - 1, Int(ceil(pointRect.maxY * scale)))
        guard endX >= startX, endY >= startY else { return 0 }
        var maxI = CGFloat(0)
        for y in startY...endY {
            for x in startX...endX {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let ink = 1 - min(c.redComponent, min(c.greenComponent, c.blueComponent))
                maxI = max(maxI, ink)
            }
        }
        return maxI
    }

    /// In insert mode the caret is a red vertical line at the byte boundary;
    /// in overwrite mode the same nibble cell carries a thick blue underline
    /// along the cell's bottom edge — below the glyph, not over it.
    func testInsertModeCaretIsRedVerticalLine() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        let rowFrame = layout.rowFrame(row: 0)
        let caretX = layout.hexByteX(column: 0)

        // Insert mode: a full-height red vertical line — sampled mid-row.
        pane.isInsertMode = true
        hexView.reloadData()
        XCTAssertGreaterThan(try redness(hexView, y: rowFrame.midY, x: caretX, width: layout.charWidth), 0.3,
                             "insert-mode caret is a red vertical line")

        // Overwrite mode: a thick blue underline at the cell's bottom edge.
        pane.isInsertMode = false
        hexView.reloadData()
        let underlineY = rowFrame.maxY - 1
        XCTAssertGreaterThan(try blueness(hexView, y: underlineY, x: caretX, width: layout.charWidth), 0.3,
                             "overwrite-mode caret is a blue underline")
        // The underline reaches the nibble cell's right edge.
        XCTAssertGreaterThan(try blueness(hexView, y: underlineY, x: caretX + layout.charWidth - 3, width: 3), 0.3,
                             "the underline spans the whole nibble cell")
        // It sits below the glyph: mid-row (where the digit ink is) has no blue
        // caret — only the black digit.
        XCTAssertLessThan(try blueness(hexView, y: rowFrame.midY, x: caretX, width: layout.charWidth), 0.3,
                          "the underline is under the glyph, not over it")
        // The bar is thick enough to overlap the row below: blue just past the
        // row's bottom edge, into the next row.
        XCTAssertGreaterThan(try blueness(hexView, y: rowFrame.maxY + 1, x: caretX, width: layout.charWidth), 0.3,
                             "the thick underline overlaps the row below")
    }

    /// After the first insert-mode digit the caret line shifts to between the
    /// two nibbles (on the low-nibble side); before it, it sits on the byte's
    /// left boundary. Sampled near the top of the row, where only the full-
    /// height caret line is present — a digit glyph is centred lower — so the
    /// red here is the caret, not the (red, modified) digit.
    func testInsertCaretShiftsToMidByteAfterFirstNibble() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        let y = layout.rowFrame(row: 0).minY + 1
        let leftEdge = layout.hexByteX(column: 0)
        let midByte = leftEdge + layout.charWidth
        pane.isInsertMode = true

        // Before the first digit: the caret line is on the byte's left boundary,
        // not mid-byte (the byte is unmodified, so the only red is the caret).
        hexView.reloadData()
        XCTAssertGreaterThan(try redness(hexView, y: y, x: leftEdge, width: 3), 0.3,
                             "before the first digit the caret line is on the left boundary")
        XCTAssertLessThan(try redness(hexView, y: y, x: midByte, width: 3), 0.3,
                          "before the first digit there is no caret line mid-byte")

        // After the first digit: the caret line shifts to between the two nibbles.
        pane.typeHexNibble(0xA)
        hexView.reloadData()
        XCTAssertGreaterThan(try redness(hexView, y: y, x: midByte, width: 3), 0.3,
                             "after the first digit the caret line is mid-byte")
    }

    /// A half-typed insert-mode byte shows a dim `_` in its low-nibble slot
    /// (muted, near the paper); the second digit fills it with the digit at
    /// full byte-text contrast.
    func testInsertModePendingNibbleShowsEmptyLowNibbleSlot() throws {
        let (hexView, pane, url) = try makeHexView([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        pane.isInsertMode = true

        // High nibble: a byte 0xA0 is inserted at offset 0, the low nibble is
        // empty (nibble == 1) and drawn as a dim `_`.
        pane.typeHexNibble(0xA)
        hexView.reloadData()
        // The insert caret now sits on the low-nibble cell's left edge (mid-
        // byte), so sample a few pixels in from that edge to read the
        // placeholder glyph's ink without counting the red caret line.
        let lowNibbleCell = CGRect(x: layout.hexByteX(column: 0) + layout.charWidth + 3,
                                   y: layout.rowFrame(row: 0).minY,
                                   width: layout.charWidth - 4, height: layout.rowHeight)
        XCTAssertLessThan(try maxInk(hexView, in: lowNibbleCell), 0.5,
                          "the pending low nibble is a dim placeholder, not a filled digit")

        // Second digit: the slot fills with "B" at full byte-text contrast.
        pane.typeHexNibble(0xB)
        hexView.reloadData()
        XCTAssertGreaterThan(try maxInk(hexView, in: lowNibbleCell), 0.5,
                             "the filled low nibble shows the digit at full contrast")
    }

    /// A mid-byte caret a *click* placed (nibble 1, nothing typed) is just a
    /// caret position — it does not open a pending insert, so the low-nibble
    /// slot keeps showing the byte's own digit at full contrast, not the dim `_`
    /// placeholder a genuine half-typed insert shows.
    func testInsertModeClickMidByteKeepsLowNibble() throws {
        let (hexView, pane, url) = try makeHexView([0xAB, 0xCD, 0xEF, 0x11, 0x22, 0x33, 0x44, 0x55])
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = hexView.hexLayout
        pane.isInsertMode = true

        // A click in the second half of byte 0 places the caret mid-byte
        // (nibble 1) without typing anything.
        pane.hexEditor(hexView, didClickAt: 0, region: .hex, extendSelection: false, nibble: 1)
        hexView.reloadData()

        // The low-nibble slot still shows the byte's own digit ("B") at full
        // contrast. Sample a few pixels in from the cell's left edge to skip
        // the red caret line.
        let lowNibbleCell = CGRect(x: layout.hexByteX(column: 0) + layout.charWidth + 3,
                                   y: layout.rowFrame(row: 0).minY,
                                   width: layout.charWidth - 4, height: layout.rowHeight)
        XCTAssertGreaterThan(try maxInk(hexView, in: lowNibbleCell), 0.5,
                             "a mid-byte click does not blank the low nibble into a placeholder")
    }

    /// The placeholder is part of the row's own string, so it leaves the cell's
    /// background alone. It used to be painted over the finished row, which
    /// meant erasing the cell first — and that erase punched a hole of plain
    /// paper through the difference orange the byte stands on (§6), exactly
    /// where insert mode is normally used: against a companion file.
    func testPendingNibbleKeepsTheDifferenceBackground() throws {
        let urlA = try tempFile([UInt8](repeating: 0x00, count: 32))
        let urlB = try tempFile([UInt8](repeating: 0xFF, count: 32))
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let paneA = PaneViewModel()
        let paneB = PaneViewModel()
        try paneA.open(url: urlA)
        try paneB.open(url: urlB)
        paneA.companion = paneB          // every byte differs → orange fill
        paneB.companion = paneA
        paneA.isInsertMode = true

        let hexView = HexView()
        hexView.appearance = NSAppearance(named: .aqua)
        hexView.dataSource = paneA
        hexView.delegate = paneA
        hexView.reloadData()
        let layout = hexView.hexLayout

        /// The difference fill's giveaway: an orange cell is much warmer than
        /// paper, which is neutral.
        func warmth(x: CGFloat, y: CGFloat) throws -> CGFloat {
            let rep = render(hexView)
            let scale = CGFloat(rep.pixelsWide) / hexView.bounds.width
            let colour = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?
                .usingColorSpace(.deviceRGB)
            return (colour?.redComponent ?? 0) - (colour?.blueComponent ?? 0)
        }

        // Sample the low-nibble cell just below the row's top edge, clear of the
        // glyph ink and of the caret line on the cell's left edge.
        let x = layout.hexByteX(column: 0) + layout.charWidth * 1.6
        let y = layout.rowFrame(row: 0).minY + 2

        let before = try warmth(x: x, y: y)
        XCTAssertGreaterThan(before, 0.1, "the byte stands on the difference fill")

        paneA.typeHexNibble(0xA)         // half-typed insert opens the slot
        hexView.reloadData()

        XCTAssertGreaterThan(try warmth(x: x, y: y), 0.1,
                             "the empty low-nibble slot keeps the difference fill under it")
    }
}
