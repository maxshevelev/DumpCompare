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

    /// The active text decoder for the decoded-text column. The view model
    /// rebuilds this whenever the user changes the decoding settings.
    var textDecoder: any TextDecoder {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var font: NSFont
    private var rowHeight: CGFloat
    private var charWidth: CGFloat
    private var baseline: CGFloat
    private var currentLayout: HexLayout
    private var wordSizeObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var textDecodingObserver: NSObjectProtocol?

    /// The window point where the current mouse-down landed; the drag-selection
    /// dead zone is anchored to it (§3.3).
    private var mouseDownLocation: CGPoint?
    /// Whether the current click has become a drag. Once the pointer leaves the
    /// dead zone the flag sticks, so later `mouseDragged` events keep extending.
    private var dragEngaged = false

    /// Ideal width of the hex grid (offset column + hex + ASCII). The window
    /// delegate uses this to zoom-to-fit (§3.1) instead of zooming to max.
    var hexContentWidth: CGFloat { currentLayout.contentWidth }

    /// Ideal height of the hex grid — all rows for the current file size. The
    /// window delegate uses this to zoom-to-fit the window height (§3.1).
    var hexContentHeight: CGFloat { currentLayout.totalHeight(fileSize: dataSource?.fileSize ?? 0) }

    /// Geometry of the current dump, used internally for hit-testing and
    /// exposed (internal) for tests. (`layout` itself is NSView's method.)
    var hexLayout: HexLayout { currentLayout }

    /// Font and baseline shared with the pane's column header, so its labels
    /// align with the rows they name.
    var hexFont: NSFont { font }
    var hexBaseline: CGFloat { baseline }

    // MARK: - Init

    init() {
        font = AppearanceSettings.font(size: 13)
        charWidth = AppearanceSettings.charWidth(for: font)
        rowHeight = Self.rowHeight(for: font)
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: rowHeight)
        currentLayout = HexLayout(charWidth: charWidth, rowHeight: rowHeight, wordSize: WordSize.current.rawValue)
        let currentSettings = TextDecodingSettingsStore().settings
        textDecoder = TextDecoderRegistry.make(identifier: currentSettings.identifier, placeholder: currentSettings.placeholder)
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
        // Re-lay out when the font or row-height factor changes (§3.2).
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        // Rebuild the decoder when text-decoding settings change.
        textDecodingObserver = NotificationCenter.default.addObserver(
            forName: TextDecodingSettingsStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTextDecodingSettings()
        }
    }

    deinit {
        if let wordSizeObserver {
            NotificationCenter.default.removeObserver(wordSizeObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let textDecodingObserver {
            NotificationCenter.default.removeObserver(textDecodingObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The vertical pitch of one row. The font's natural line height (glyph
    /// ascender→descender, padded by 4pt for breathing room) is scaled down by
    /// the user's row-height factor so more information fits on screen. The
    /// baseline is recomputed from the resulting height, so the glyph ink stays
    /// vertically centred in the tighter row (§3.2).
    private static func rowHeight(for font: NSFont) -> CGFloat {
        let natural = ceil(font.ascender - font.descender) + 4
        return ceil(natural * AppearanceSettings.rowHeightScale)
    }

    /// Re-derives the font metrics and re-lays out after an Appearance change
    /// (§3.2). The frame grows or shrinks with the new row height, so the
    /// enclosing scroll view picks up the new content size.
    private func applyAppearance() {
        font = AppearanceSettings.font(size: 13)
        charWidth = AppearanceSettings.charWidth(for: font)
        rowHeight = Self.rowHeight(for: font)
        baseline = AppearanceSettings.centeredBaseline(font: font, rowHeight: rowHeight)
        reloadData()
    }

    /// Rebuilds the active text decoder from the current settings.
    private func applyTextDecodingSettings() {
        let store = TextDecodingSettingsStore()
        let currentSettings = store.settings
        textDecoder = TextDecoderRegistry.make(identifier: currentSettings.identifier, placeholder: currentSettings.placeholder)
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
             baseline: baseline, color: HexTheme.inkBlue)

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

            let textColor = HexTheme.textColor(for: state)
            let digits = hexDigits(state.byte)
            draw(text: digits, in: hexFrame, baseline: baseline, color: textColor)

            let asciiChar = textDecoder.decode(state.byte)
            let isDisplayable = textDecoder.isDisplayable(state.byte)
            let asciiColor = isDisplayable ? textColor : HexTheme.mutedTextColor
            draw(text: String(asciiChar), in: asciiRect, baseline: baseline, color: asciiColor)
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
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        // A shift-click extends immediately; an unmodified click needs to leave
        // the dead zone before the selection engages.
        dragEngaged = event.modifierFlags.contains(.shift)
        handleMouse(event, extendSelection: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragEngaged {
            let point = convert(event.locationInWindow, from: nil)
            if let origin = mouseDownLocation, !dragHasLeftDeadZone(from: origin, to: point) {
                return  // still a click — the pointer has not left the dead zone
            }
            dragEngaged = true
        }
        handleMouse(event, extendSelection: true)
    }

    /// Whether a drag started at `origin` has moved far enough at `point` to
    /// extend the selection. A hex click that lands inside a byte's dead zone —
    /// from the middle of the high-nibble character to the middle of the
    /// low-nibble one (§3.3) — is a mid-byte caret placement, so it must leave
    /// the zone before a drag selects: the zone's boundary sits on the byte's
    /// centre, where a 1 px jitter would otherwise flip the selection end and
    /// select the byte by accident. Clicks outside the zone (a byte's outer
    /// quarters, or the offset/ASCII columns) are clear positions and any drag
    /// engages immediately. The zone spans the click's row, so vertical
    /// movement engages too.
    private func dragHasLeftDeadZone(from origin: CGPoint, to point: CGPoint) -> Bool {
        let layout = currentLayout
        guard let dataSource else { return true }
        let rowCount = layout.rowCount(fileSize: dataSource.fileSize)
        guard let hit = layout.hitTest(point: origin, rowCount: rowCount),
              case .hex(let column) = hit.column else { return true }
        let rowFrame = layout.rowFrame(row: hit.row)
        let zoneMinX = layout.highNibbleMidX(column: column)
        let zoneMaxX = layout.lowNibbleMidX(column: column)
        let originInZone = origin.x >= zoneMinX && origin.x <= zoneMaxX
            && origin.y >= rowFrame.minY && origin.y <= rowFrame.maxY
        guard originInZone else { return true }
        let pointInZone = point.x >= zoneMinX && point.x <= zoneMaxX
            && point.y >= rowFrame.minY && point.y <= rowFrame.maxY
        return !pointInZone
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
            if dataSource.hexInputRegion() == .hex {
                // Hex column: only printable ASCII digits are meaningful.
                guard value >= 0x20, value <= 0x7E else {
                    super.keyDown(with: event)
                    return
                }
                if let digit = Self.hexDigitValue(value) {
                    delegate.hexEditor(self, typeHexNibble: digit)
                } else {
                    NSSound.beep()
                }
            } else {
                // Decoded text column: any non-control key is tried against the
                // active decoding table; characters it can't encode are rejected
                // with a beep (§3.2).
                guard value >= 0x20 else {
                    super.keyDown(with: event)
                    return
                }
                let character = Character(UnicodeScalar(value)!)
                if let byte = textDecoder.encode(character) {
                    delegate.hexEditor(self, typeASCIIByte: byte)
                } else {
                    NSSound.beep()
                }
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

    /// Text for "fill" bytes (0x00, 0xFF) — the label dimmed so significant
    /// bytes stand out (§6). A translucent label keeps the colour mode-correct
    /// and stays legible over selection and difference fills.
    static let mutedByteText = NSColor(name: nil) { _ in
        NSColor.labelColor.withAlphaComponent(0.40)
    }

    /// Muted color for placeholder characters in the decoded text column.
    static let mutedTextColor = NSColor(name: nil) { _ in
        NSColor.labelColor.withAlphaComponent(0.35)
    }

    static let modifiedText = NSColor.systemRed
    static let caretColor = NSColor.controlAccentColor

    /// Ink blue for the column header and the offset column (§6): a pale,
    /// slightly desaturated blue that reads as a quiet secondary element next
    /// to the dump's byte content, lighter on dark backgrounds so it stays
    /// legible without competing with the bytes.
    static let inkBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.58, green: 0.73, blue: 0.92, alpha: 1)
            : NSColor(srgbRed: 0.33, green: 0.54, blue: 0.78, alpha: 1)
    }

    /// Text colour for a byte. A modified byte keeps its red warning; otherwise
    /// a fill byte (0x00, 0xFF) is drawn muted so the significant bytes read
    /// more contrasty than the padding around them (§6).
    static func textColor(for state: HexByteState) -> NSColor {
        if state.isModified { return modifiedText }
        if state.byte == 0x00 || state.byte == 0xFF { return mutedByteText }
        return byteText
    }

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
