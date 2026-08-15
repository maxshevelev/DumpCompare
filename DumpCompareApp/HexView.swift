import Cocoa
import DumpCompareCore

/// Supplies the bytes and selection the hex view renders (§6).
@MainActor
protocol HexViewDataSource: AnyObject {
    var fileSize: UInt64 { get }
    func hexByteStates(in range: Range<UInt64>) -> [HexByteState]
    func hexSelection() -> SelectionModel
    func hexCaretNibble() -> Int
    func hexInputRegion() -> HexInputRegion
}

/// Receives editing input from the hex view (§7). The view-model owns caret,
/// selection, and edit semantics; the view only captures input and renders.
@MainActor
protocol HexEditorDelegate: AnyObject {
    func hexEditor(_ editor: HexView, typeHexNibble digit: Int)
    func hexEditor(_ editor: HexView, typeASCIIByte byte: UInt8)
    func hexEditorDeleteForward(_ editor: HexView)
    func hexEditorDeleteBackward(_ editor: HexView)
    func hexEditor(_ editor: HexView, moveCaretBy delta: Int64, extendSelection: Bool)
    func hexEditor(_ editor: HexView, moveCaretTo offset: UInt64, extendSelection: Bool)
    func hexEditorSelectAll(_ editor: HexView)
    func hexEditor(_ editor: HexView, didClickAt offset: UInt64, region: HexInputRegion, extendSelection: Bool, nibble: Int)
}

/// A virtualized hex dump: only rows intersecting the visible rect are drawn,
/// so arbitrarily large files scroll without materializing their rows (§6,
/// §13.8). Rendered from a `HexViewDataSource` and driven by a
/// `HexEditorDelegate`.
final class HexView: NSView {
    weak var dataSource: HexViewDataSource?
    weak var delegate: HexEditorDelegate?

    /// Fired when this hex view becomes the window's first responder, i.e. the
    /// pane the user is actually editing in. The pane uses it to make the
    /// active-pane pointer follow keyboard focus (§3.3), so clicking a dump and
    /// typing into it always target the same pane.
    var onFocus: (() -> Void)?

    /// Whether this hex view is the active pane. The caret is drawn only on the
    /// active pane; inactive panes draw a thin mirror frame around the byte the
    /// active pane's caret points at instead (§3.3). Defaults to true
    /// (single-file mode).
    var isActive = true {
        didSet { needsDisplay = true }
    }

    /// Accessible label for the grid, e.g. "Hex dump — File A" (§15).
    var accessibilityTitle = "Hex dump"

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private let font: NSFont
    private let rowHeight: CGFloat
    private let charWidth: CGFloat
    private let baseline: CGFloat
    private var currentLayout: HexLayout
    private var wordSizeObserver: NSObjectProtocol?

    /// Ideal width of the hex grid (offset column + hex + ASCII). The window
    /// delegate uses this to zoom-to-fit (§3.1) instead of zooming to max.
    var hexContentWidth: CGFloat { currentLayout.contentWidth }

    /// Geometry of the current dump, used internally for hit-testing and
    /// exposed (internal) for tests. (`layout` itself is NSView's method.)
    var hexLayout: HexLayout { currentLayout }

    // MARK: - Init

    init() {
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        charWidth = Self.measureCharWidth(font)
        rowHeight = ceil((font.ascender - font.descender)) + 4
        baseline = Self.centeredBaseline(font: font, rowHeight: rowHeight)
        currentLayout = HexLayout(charWidth: charWidth, rowHeight: rowHeight, wordSize: WordSize.current.rawValue)
        super.init(frame: .zero)
        // Expose the grid to VoiceOver with a live value describing the caret
        // and selection (§15 accessibility).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Re-lay out when the word size changes (§6).
        wordSizeObserver = NotificationCenter.default.addObserver(
            forName: WordSize.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
    }

    deinit {
        if let wordSizeObserver {
            NotificationCenter.default.removeObserver(wordSizeObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func measureCharWidth(_ font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    /// The baseline that places the glyph ink vertically centered in the row.
    /// `NSString.draw(at:)` anchors the text's ascent line at the point in a
    /// flipped view, so centering the ascent box alone would push the ink low in
    /// the row (a font's ascender far exceeds its cap height). Measure the ink
    /// bounds of a representative glyph and solve for the point that centers
    /// those bounds in `rowHeight` (§3.2).
    private static func centeredBaseline(font: NSFont, rowHeight: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0A", attributes: [.font: font]))
        let ink = CTLineGetImageBounds(line, nil)
        // ink.minY sits below the baseline (negative), ink.maxY above it.
        return rowHeight / 2 - (font.ascender + font.leading) + (ink.minY + ink.maxY) / 2
    }

    // MARK: - Data refresh

    /// Recomputes the content frame and redraws. Call when the file size or
    /// selection changes.
    func reloadData() {
        currentLayout = makeLayout()
        let height = currentLayout.totalHeight(fileSize: dataSource?.fileSize ?? 0)
        let width = max(currentLayout.contentWidth, enclosingScrollView?.contentSize.width ?? currentLayout.contentWidth)
        if width != frame.width || height != frame.height {
            setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    private func makeLayout() -> HexLayout {
        let fileSize = dataSource?.fileSize ?? 0
        let digits = max(8, fileSize > 0 ? String(fileSize, radix: 16).count : 8)
        return HexLayout(charWidth: charWidth, rowHeight: rowHeight,
                         offsetColumnChars: digits, wordSize: WordSize.current.rawValue)
    }

    override func layout() {
        super.layout()
        // Keep the content width at least the scroll view's width.
        if let scroll = enclosingScrollView {
            setFrameSize(NSSize(width: max(frame.width, scroll.contentSize.width), height: frame.height))
        }
    }

    // MARK: - Accessibility (§15)

    override func accessibilityLabel() -> String? { accessibilityTitle }

    override func accessibilityValue() -> Any? {
        guard let dataSource else { return "" }
        let selection = dataSource.hexSelection()
        let size = dataSource.fileSize
        let start = String(selection.start, radix: 16).uppercased()
        if selection.isEmpty {
            return "Offset 0x\(start). File size \(size) bytes."
        }
        let end = String(selection.end, radix: 16).uppercased()
        return "Offset 0x\(start), \(selection.count) bytes selected through 0x\(end). File size \(size) bytes."
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        let ok = super.becomeFirstResponder()
        if ok {
            onFocus?()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        guard let dataSource else { return }
        let layout = currentLayout
        let fileSize = dataSource.fileSize
        let rowCount = layout.rowCount(fileSize: fileSize)
        let selection = dataSource.hexSelection()
        let nibble = dataSource.hexCaretNibble()
        let region = dataSource.hexInputRegion()

        let rows = layout.visibleRowRange(in: dirtyRect)

        for row in rows {
            guard UInt64(row) < rowCount else { break }
            drawRow(
                row: row, layout: layout, fileSize: fileSize,
                selection: selection, baseline: baseline
            )
        }

        // Caret: only on the active pane, and only when there is no selection.
        if isActive && selection.isEmpty {
            drawCaret(offset: selection.start, layout: layout, nibble: nibble, region: region, rowCount: rowCount)
        }

        // Frame the byte the caret points at. On the inactive pane that is the
        // whole byte (hex cell + ASCII char), mirroring the active caret across
        // panes; on the active pane it is the byte in the column the caret is
        // not in, linking the hex and ASCII views of the same byte (§3.3).
        drawFrames(isActive ? activeCrossFrameRects() : mirrorFrameRects())
    }

    private func drawRow(row: Int, layout: HexLayout, fileSize: UInt64,
                         selection: SelectionModel, baseline: CGFloat) {
        let rowStart = layout.byteOffset(row: row, column: 0)

        // Offset column.
        let offsetText = String(rowStart, radix: 16, uppercase: true).leftPadded(to: layout.offsetColumnChars, with: "0")
        draw(text: offsetText, in: layout.offsetColumnFrame(row: row),
             baseline: baseline, color: .secondaryLabelColor)

        let states = dataSource?.hexByteStates(in: rowStart..<rowStart + 16) ?? []
        for column in 0..<HexLayout.bytesPerRow {
            let offset = layout.byteOffset(row: row, column: column)
            let state = states.indices.contains(column) ? states[column] : HexByteState(isEOF: true)
            let isSelected = offset >= selection.start && offset < selection.end

            let hexFrame = layout.hexByteFrame(row: row, column: column)
            let asciiRect = CGRect(x: layout.asciiX(column: column),
                                   y: hexFrame.minY, width: layout.charWidth, height: layout.rowHeight)

            if state.isEOF {
                HexTheme.eofFill.setFill()
                NSBezierPath(rect: hexFrame).fill()
                NSBezierPath(rect: asciiRect).fill()
                // Style cue for EOF (§15): a fine diagonal hatch over the muted
                // fill so the file's end reads without relying on color alone.
                drawEOFHatch(in: [hexFrame, asciiRect])
                continue
            }

            // Difference (comparison, M5) and selection backgrounds.
            if state.isDifferent {
                HexTheme.differenceFill.setFill()
                NSBezierPath(rect: hexFrame).fill()
                NSBezierPath(rect: asciiRect).fill()
            }
            if isSelected {
                HexTheme.selectionFill.setFill()
                NSBezierPath(rect: hexFrame).fill()
                NSBezierPath(rect: asciiRect).fill()
            }

            let textColor = state.isModified ? HexTheme.modifiedText : HexTheme.byteText
            let digits = hexDigits(state.byte)
            draw(text: digits, in: hexFrame, baseline: baseline, color: textColor)

            let asciiChar = printableAscii(state.byte)
            draw(text: asciiChar, in: asciiRect, baseline: baseline, color: textColor)
        }
    }

    /// Draws a fine diagonal hatch over the given rects to mark EOF cells.
    private func drawEOFHatch(in rects: [CGRect]) {
        HexTheme.eofHatch.setStroke()
        for rect in rects {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2))
            path.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2))
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Frames the mirror caret draws on an inactive pane: the hex cell and ASCII
    /// char of the byte the active pane's caret points at (this pane's synced
    /// selection start). Empty when this pane is active, has no data, or the
    /// caret is at EOF. Exposed (internal) for tests.
    func mirrorFrameRects() -> [CGRect] {
        guard !isActive, let dataSource else { return [] }
        let fileSize = dataSource.fileSize
        let offset = dataSource.hexSelection().start
        guard offset < fileSize else { return [] }
        let layout = currentLayout
        let (row, column) = layout.rowColumn(of: offset)
        let hexFrame = layout.hexByteFrame(row: row, column: column)
        let asciiRect = CGRect(x: layout.asciiX(column: column), y: hexFrame.minY,
                               width: layout.charWidth, height: layout.rowHeight)
        return [hexFrame, asciiRect]
    }

    /// Frames the cross-column link drawn on the active pane: the byte's hex
    /// cell when the caret is in the ASCII region, or its ASCII char when the
    /// caret is in the hex region — so the same byte is highlighted in both
    /// columns. Empty when this pane is inactive, has no data, or the caret is
    /// at EOF. Exposed (internal) for tests.
    func activeCrossFrameRects() -> [CGRect] {
        guard isActive, let dataSource else { return [] }
        let fileSize = dataSource.fileSize
        let offset = dataSource.hexSelection().start
        guard offset < fileSize else { return [] }
        let layout = currentLayout
        let (row, column) = layout.rowColumn(of: offset)
        if dataSource.hexInputRegion() == .ascii {
            return [layout.hexByteFrame(row: row, column: column)]
        }
        let hexFrame = layout.hexByteFrame(row: row, column: column)
        let asciiRect = CGRect(x: layout.asciiX(column: column), y: hexFrame.minY,
                               width: layout.charWidth, height: layout.rowHeight)
        return [asciiRect]
    }

    /// Draws 1px accent frames around the given rects.
    private func drawFrames(_ rects: [CGRect]) {
        guard !rects.isEmpty else { return }
        HexTheme.mirrorFrame.setStroke()
        for rect in rects {
            // 1px frame inset by half a point so the stroke sits on the pixel
            // grid rather than straddling the cell edge.
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawCaret(offset: UInt64, layout: HexLayout, nibble: Int,
                           region: HexInputRegion, rowCount: UInt64) {
        let (row, column) = layout.rowColumn(of: offset)
        guard UInt64(row) < rowCount else { return }
        let x: CGFloat
        let width: CGFloat
        if region == .ascii {
            x = layout.asciiX(column: column)
            width = 1
        } else {
            x = layout.caretX(row: row, column: column, nibble: nibble)
            width = 2
        }
        let rect = CGRect(x: x, y: layout.rowFrame(row: row).minY, width: width, height: layout.rowHeight)
        HexTheme.caretColor.setFill()
        NSBezierPath(rect: rect).fill()
    }

    // MARK: - Text helpers

    private func hexDigits(_ byte: UInt8) -> String {
        let table = Self.hexTable
        return "\(table[Int(byte >> 4)])\(table[Int(byte & 0x0F)])"
    }

    private static let hexTable = Array("0123456789ABCDEF")

    private func printableAscii(_ byte: UInt8) -> String {
        (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
    }

    private func draw(text: String, in frame: CGRect, baseline: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        (text as NSString).draw(at: NSPoint(x: frame.minX, y: frame.minY + baseline), withAttributes: attributes)
    }

    // MARK: - Scrolling

    /// Scrolls the caret into view within the enclosing scroll view.
    func revealCaret() {
        guard let dataSource else { return }
        let layout = currentLayout
        let selection = dataSource.hexSelection()
        let (row, column) = layout.rowColumn(of: selection.start)
        let region = dataSource.hexInputRegion()
        let rect: CGRect
        if region == .ascii {
            rect = CGRect(x: layout.asciiX(column: column),
                          y: layout.rowFrame(row: row).minY,
                          width: layout.charWidth, height: layout.rowHeight)
        } else {
            rect = layout.hexByteFrame(row: row, column: column)
        }
        scrollToVisible(rect)
    }

    /// Scrolls the row containing `offset` to the vertical centre of the visible
    /// area (clamped to the document's edges), so the byte is shown mid-pane
    /// instead of at its top or bottom edge. Used after a search result lands
    /// (§11).
    func revealOffsetCentered(_ offset: UInt64) {
        guard let scroll = enclosingScrollView else { return }
        let layout = currentLayout
        let (row, _) = layout.rowColumn(of: offset)
        let rowFrame = layout.rowFrame(row: row)
        let clip = scroll.contentView
        let maxOriginY = max(0, bounds.height - clip.bounds.height)
        let originY = min(max(0, rowFrame.midY - clip.bounds.height / 2), maxOriginY)
        guard abs(originY - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: originY))
        scroll.reflectScrolledClipView(clip)
    }

    /// Scrolls the current selection (or the caret when there is none) to the
    /// vertical centre of the visible area.
    func revealSelectionCentered() {
        guard let dataSource else { return }
        let selection = dataSource.hexSelection()
        let offset = selection.isEmpty ? selection.start : selection.start + selection.count / 2
        revealOffsetCentered(offset)
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouse(event, extendSelection: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        handleMouse(event, extendSelection: true)
    }

    private func handleMouse(_ event: NSEvent, extendSelection: Bool) {
        guard let dataSource, let delegate else { return }
        let point = convert(event.locationInWindow, from: nil)
        let layout = currentLayout
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)

        // Dragging (or shift-click) extends the selection. The pointer maps to
        // the byte whose cell-centre it has crossed (§6), so the byte under the
        // pointer joins the selection — including the row's last byte, which
        // needs no following byte to be reachable.
        if extendSelection {
            guard let end = layout.dragEndOffset(point: point, rowCount: rowCount) else { return }
            let asciiStart = layout.asciiX(column: 0)
            let region: HexInputRegion = (point.x >= asciiStart && point.x < asciiStart + layout.asciiColumnWidth)
                ? .ascii : .hex
            delegate.hexEditor(self, didClickAt: end, region: region, extendSelection: true, nibble: 0)
            return
        }

        guard let hit = layout.hitTest(point: point, rowCount: rowCount) else { return }

        let offset: UInt64
        let region: HexInputRegion
        var nibble = 0
        switch hit.column {
        case .offset:
            offset = layout.byteOffset(row: hit.row, column: 0)
            region = .hex
        case .hex(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            region = .hex
            // A click on the first half of the byte's high-nibble char places
            // the caret before it; anywhere from the second half of that char
            // onward places it between the two chars — a large target, so the
            // mid-byte caret is easy to reach without aiming at the gap (§3.3).
            nibble = (point.x - layout.hexByteX(column: column)) >= layout.charWidth / 2 ? 1 : 0
        case .ascii(let column):
            offset = layout.byteOffset(row: hit.row, column: column)
            region = .ascii
        }
        delegate.hexEditor(self, didClickAt: offset, region: region, extendSelection: extendSelection, nibble: nibble)
    }

    override func keyDown(with event: NSEvent) {
        guard let delegate, let dataSource else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            // Cmd+A / Cmd+C / Cmd+V / Cmd+G… are handled by menu key
            // equivalents; leave this keystroke to the menu system.
            super.keyDown(with: event)
            return
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        let extend = flags.contains(.shift)
        guard let first = chars.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        let value = first.value

        switch value {
        case 0x7F:  // Backspace — fills the previous byte with 0x00 (§7.3)
            delegate.hexEditorDeleteBackward(self)
        case 0xF728:  // Forward Delete — fills the current byte with 0x00
            delegate.hexEditorDeleteForward(self)
        case 0xF700:  // Up
            delegate.hexEditor(self, moveCaretBy: -Int64(HexLayout.bytesPerRow), extendSelection: extend)
        case 0xF701:  // Down
            delegate.hexEditor(self, moveCaretBy: Int64(HexLayout.bytesPerRow), extendSelection: extend)
        case 0xF702:  // Left
            delegate.hexEditor(self, moveCaretBy: -1, extendSelection: extend)
        case 0xF703:  // Right
            delegate.hexEditor(self, moveCaretBy: 1, extendSelection: extend)
        case 0xF72C:  // Page Up
            delegate.hexEditor(self, moveCaretBy: -Int64(pageStep()), extendSelection: extend)
        case 0xF72D:  // Page Down
            delegate.hexEditor(self, moveCaretBy: Int64(pageStep()), extendSelection: extend)
        case 0xF729:  // Home
            delegate.hexEditor(self, moveCaretTo: 0, extendSelection: extend)
        case 0xF72B:  // End
            delegate.hexEditor(self, moveCaretTo: dataSource.fileSize, extendSelection: extend)
        case 0x1B:  // Escape
            super.keyDown(with: event)
        default:
            guard value >= 0x20, value <= 0x7E else {
                super.keyDown(with: event)
                return
            }
            if dataSource.hexInputRegion() == .hex {
                if let digit = Self.hexDigitValue(value) {
                    delegate.hexEditor(self, typeHexNibble: digit)
                } else {
                    NSSound.beep()
                }
            } else {
                delegate.hexEditor(self, typeASCIIByte: UInt8(value))
            }
        }
    }

    private func pageStep() -> Int {
        max(1, Int(bounds.height / currentLayout.rowHeight)) * HexLayout.bytesPerRow
    }

    private static func hexDigitValue(_ scalar: UInt32) -> Int? {
        switch scalar {
        case 0x30...0x39: return Int(scalar - 0x30)
        case 0x41...0x46: return Int(scalar - 0x41) + 10
        case 0x61...0x66: return Int(scalar - 0x61) + 10
        default: return nil
        }
    }
}

/// Dynamic colors for hex cells (§6: Dark Mode support, difference = background,
/// unsaved modification = red foreground, selection stays legible).
enum HexTheme {
    static let byteText = NSColor.labelColor
    static let modifiedText = NSColor.systemRed
    static let caretColor = NSColor.controlAccentColor

    static let differenceFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemOrange.withAlphaComponent(0.45)
            : NSColor.systemOrange.withAlphaComponent(0.35)
    }

    static let selectionFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemBlue.withAlphaComponent(0.35)
            : NSColor.systemBlue.withAlphaComponent(0.22)
    }

    static let eofFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 0.5)
            : NSColor(white: 0.80, alpha: 0.5)
    }

    /// Hatch strokes over EOF cells (a non-color "end of file" cue, §15).
    static let eofHatch = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.55, alpha: 0.6)
            : NSColor(white: 0.45, alpha: 0.6)
    }

    /// Thin frame around the byte the active pane's caret points at, drawn on
    /// the inactive pane (§3.3). The accent color ties it to the caret itself.
    static let mirrorFrame = NSColor.controlAccentColor
}

extension String {
    /// Left-pads with `pad` until the string is at least `length` characters.
    func leftPadded(to length: Int, with pad: String) -> String {
        guard count < length else { return self }
        return String(repeating: pad, count: length - count) + self
    }
}
