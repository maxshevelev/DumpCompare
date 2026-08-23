import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Right-click on an address in the Offset column frames it and offers
/// "Select block from here" (§10.2). `rightMouseDown` itself pops the menu with
/// `NSMenu.popUpContextMenu`, which runs a blocking tracking loop, so these
/// tests exercise the pieces around it: the hit-test → offset mapping that
/// decides whether a right-click lands on an address at all.
@MainActor
final class OffsetContextMenuTests: XCTestCase {
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

    /// Window point of a right-click on `row`'s address in the Offset column.
    private func offsetCentre(_ hexView: HexView, row: Int) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.offsetColumnFrame(row: row).midX,
                            y: CGFloat(row) * layout.rowHeight)
        return hexView.convert(local, to: nil)
    }

    // MARK: - Offset-column and hex-byte hits

    /// A right-click on an address maps to that row's start offset — what the
    /// "Select block from here" sheet pre-fills — and frames the address rather
    /// than a byte. The first row's 0x00000000 is a valid start like any other.
    func testOffsetAnchorFramesRowAddress() throws {
        let (_, _, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }

        for (row, expected) in [(0, UInt64(0)), (1, 0x10), (2, 0x20)] {
            let event = mouse(.rightMouseDown, at: offsetCentre(hexView, row: row), window: window)
            let anchor = try XCTUnwrap(hexView.contextMenuAnchor(for: event),
                                       "row \(row)'s address must anchor a menu")
            XCTAssertEqual(anchor.offset, expected,
                           "row \(row)'s address maps to its own start offset")
            XCTAssertFalse(anchor.framesByte,
                           "the offset-column frame spans the row's address")
        }
    }

    /// A right-click on a hex byte anchors the SAME menu to that byte's own
    /// offset, framed as a single byte, on any row (§10.2).
    func testRightClickOnHexByteMapsToByteOffset() throws {
        let (_, _, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = hexView.hexLayout
        for (row, column, expected) in [(0, 4, UInt64(0x04)), (2, 3, 0x23)] {
            let local = CGPoint(x: layout.hexByteX(column: column) + layout.charWidth,
                                y: CGFloat(row) * layout.rowHeight)
            let event = mouse(.rightMouseDown, at: hexView.convert(local, to: nil), window: window)
            let anchor = try XCTUnwrap(hexView.contextMenuAnchor(for: event),
                                       "row \(row) column \(column) must anchor a menu")
            XCTAssertEqual(anchor.offset, expected,
                           "the context offset is the clicked byte's own offset")
            XCTAssertTrue(anchor.framesByte,
                          "the frame must wrap the byte, not the offset column")
        }
    }

    /// The ASCII column is not a byte address — right-clicking it stays inert.
    func testRightClickInAsciiColumnIsIgnored() throws {
        let (_, _, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.asciiX(column: 2), y: CGFloat(0) * layout.rowHeight)
        let event = mouse(.rightMouseDown, at: hexView.convert(local, to: nil), window: window)
        XCTAssertNil(hexView.rightClickedOffset(for: event))
    }

    /// Nothing past EOF anchors a menu: a file ending exactly on a row boundary
    /// keeps a trailing caret row, and neither its placeholder hex byte nor its
    /// address is a block to start from. An empty file is the same rule with
    /// that row first.
    func testRightClickPastEOFIsIgnored() throws {
        let (_, _, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        let layout = hexView.hexLayout
        let placeholder = CGPoint(x: layout.hexByteX(column: 0) + layout.charWidth,
                                  y: CGFloat(2) * layout.rowHeight)  // caret row past EOF
        let onByte = mouse(.rightMouseDown, at: hexView.convert(placeholder, to: nil), window: window)
        XCTAssertNil(hexView.rightClickedOffset(for: onByte),
                     "the caret row's placeholder byte has no offset")

        let onAddress = mouse(.rightMouseDown, at: offsetCentre(hexView, row: 2), window: window)
        XCTAssertNil(hexView.rightClickedOffset(for: onAddress),
                     "nor does the caret row's own address")

        let (_, _, emptyHex, emptyWindow, emptyURL) = try makePane([])
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let onEmpty = mouse(.rightMouseDown, at: offsetCentre(emptyHex, row: 0), window: emptyWindow)
        XCTAssertNil(emptyHex.rightClickedOffset(for: onEmpty),
                     "an empty file offers no address to start a block from")
    }

    // MARK: - Menu anchor state

    // MARK: - Frame invalidation (§10.2)

    /// The regression: clearing the frame after the menu must invalidate the
    /// anchor's rows even though `contextMenuOffset` is already nil at that
    /// moment — the old code called a no-argument helper that `guard`ed on the
    /// nil anchor and returned silently, so §13 region-redraw preserved the
    /// focus ring on screen. `invalidateContextMenuFrame` takes the offset
    /// explicitly, so the clearing call is stateless and marks the view dirty
    /// whatever the anchor state.
    func testClearingContextMenuFrameInvalidatesAnchorRows() {
        let hexView = HexView()
        let rowHeight = hexView.hexLayout.rowHeight
        XCTAssertGreaterThan(rowHeight, 0)

        // The state rightMouseDown leaves behind once the menu closes.
        XCTAssertNil(hexView.contextMenuOffset, "the menu is down, so the anchor is already cleared")

        // The clearing invalidation must still reach the anchor's rows — the
        // old code's `guard let contextMenuOffset` returned silently, and §3.3
        // region-redraw preserved the focus ring's pixels on screen.
        let rows = invalidatedRows(hexView.invalidateContextMenuFrame(for: 0x21), rowHeight: rowHeight)
        XCTAssertEqual(rows, [1, 2, 3], "0x21 is row 2; its frame draws on row 2 and the neighbours")

        // Row 0 has no neighbour above; the invalidation still reaches it and
        // the row below.
        let firstRow = invalidatedRows(hexView.invalidateContextMenuFrame(for: 0x00), rowHeight: rowHeight)
        XCTAssertEqual(firstRow, [0, 1])
    }

    /// The set of row indices the returned rects cover, so the assertion reads
    /// as "rows {1, 2, 3} are invalidated" rather than comparing pixel rects.
    private func invalidatedRows(_ rects: [CGRect], rowHeight: CGFloat) -> [Int] {
        rects.map { Int(($0.minY / rowHeight).rounded()) }.sorted()
    }

    /// The pane forwards its offset-menu provider to the hex view, so a
    /// right-click menu resolves the pane's offset (the MainViewController
    /// wiring test: FilePaneView.offsetMenuProvider → HexView.offsetMenuProvider).
    func testPaneForwardsOffsetMenuProvider() throws {
        let (filePane, _, hexView, _, url) = try makePane([UInt8](repeating: 0x11, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }

        var received: UInt64?
        filePane.offsetMenuProvider = { offset in
            received = offset
            let menu = NSMenu(title: "Offset")
            menu.addItem(withTitle: "Select block from here", action: nil, keyEquivalent: "")
            return menu
        }
        let menu = try XCTUnwrap(hexView.offsetMenuProvider?(0x20))
        XCTAssertEqual(menu.items.map(\.title), ["Select block from here"])
        XCTAssertEqual(received, 0x20)
    }

    // MARK: - Copy offset

    /// The offset context menu leads with "Copy offset" (a separator splits it
    /// from "Select block from here"); invoking it writes the right-clicked
    /// offset to the clipboard as BARE hex digits — no "0x" prefix, so a paste
    /// into an offset field (which already carries its own "0x") doesn't double
    /// it ("24", not "0x24").
    func testCopyOffsetCopiesHexOffsetToClipboard() {
        let controller = MainViewController()
        let menu = controller.makeOffsetMenu(for: PaneViewModel(), offset: 0x24)

        XCTAssertEqual(menu.items.count, 6,
                       "Copy offset, separator, Select block from here, Split Here, separator, Toggle Bookmark")
        XCTAssertEqual(menu.items[0].title, "Copy offset")
        XCTAssertEqual(menu.items[0].action, #selector(MainViewController.copyOffset(_:)))
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "Select block from here")
        XCTAssertEqual(menu.items[2].action, #selector(MainViewController.selectBlockFromHere(_:)))
        XCTAssertEqual(menu.items[3].title, "Split Here")
        XCTAssertEqual(menu.items[3].action, #selector(MainViewController.splitHere(_:)))

        // Snapshot the clipboard so the test leaves it untouched. Restore by
        // re-writing the string — resurrecting `pasteboardItems` throws
        // "already associated with another pasteboard".
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedString { pasteboard.setString(savedString, forType: .string) }
        }

        let copyItem = menu.items[0]
        let dispatched = NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem)
        XCTAssertTrue(dispatched, "the Copy offset action must dispatch")
        XCTAssertEqual(pasteboard.string(forType: .string), "24",
                       "the copied offset must carry no 0x prefix")

        // Zero is neither padded nor prefixed either.
        let zero = controller.makeOffsetMenu(for: PaneViewModel(), offset: 0)
        NSApp.sendAction(zero.items[0].action!, to: zero.items[0].target, from: zero.items[0])
        XCTAssertEqual(pasteboard.string(forType: .string), "0",
                       "offset zero copies as \"0\", unpadded")
    }

    // MARK: - Selection-aware menu (§10.2)

    /// A right-click on a byte INSIDE the pane's selection adds the selection
    /// actions to the menu, ahead of the offset actions, with a separator
    /// splitting the two groups.
    func testMenuGainsSelectionActionsWhenByteInSelection() throws {
        let (_, pane, _, _, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 0x10, end: 0x20, fileSize: 48))

        let controller = MainViewController()
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x14)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles,
                       ["Copy", "Fill Selection with…", "Delete Bytes…",
                        "",                     // separator
                        "Copy offset", "",
                        "Select block from here", "Split Here", "",
                        // The bookmark block: one item marks and unmarks, and an
                        // unmarked row has nothing to rename (§20.3).
                        "Toggle Bookmark at 0x00000010"])

        // The selection items act on the pane they were built for.
        let copy = menu.items[0]
        XCTAssertEqual(copy.action, #selector(MainViewController.copyPaneSelection(_:)))
        XCTAssertTrue(copy.target === controller)
        XCTAssertEqual(menu.items[1].action, #selector(MainViewController.fillPaneSelection(_:)))
        XCTAssertEqual(menu.items[2].action, #selector(MainViewController.deletePaneSelection(_:)))
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertTrue(menu.items[5].isSeparatorItem)
    }

    /// Selection membership is half-open: the byte at `start` qualifies, the
    /// byte just past `end` does not. A byte outside gets the plain offset menu
    /// back, with no selection actions in front of it.
    func testOnlyBytesInsideTheHalfOpenSelectionGetSelectionActions() throws {
        let (_, pane, _, _, url) = try makePane([UInt8](repeating: 0x11, count: 48))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 0x10, end: 0x20, fileSize: 48))

        let controller = MainViewController()
        let inside = controller.makeOffsetMenu(for: pane, offset: 0x10)
        XCTAssertEqual(inside.items.map(\.title)[0], "Copy",
                       "the selection start byte is inside the selection")

        // 0x20 is `end` itself — one past the last selected byte — and 0x24 is
        // well clear of it; both keep the plain menu, all five items of it.
        for outside: UInt64 in [0x20, 0x24] {
            let menu = controller.makeOffsetMenu(for: pane, offset: outside)
            XCTAssertEqual(menu.items.map(\.title),
                           ["Copy offset", "", "Select block from here", "Split Here", "",
                            "Toggle Bookmark at 0x00000020"],
                           "0x\(String(outside, radix: 16)) is outside: no selection actions")
        }
    }

    /// The context Copy copies the RIGHT-CLICKED pane's selection bytes — never
    /// the active pane's. A fresh controller's active pane has no document, so
    /// if the action fell back to it nothing would reach the clipboard.
    func testSelectionCopyCopiesTheRightClickedPanesBytes() throws {
        let (_, pane, _, _, url) = try makePane([UInt8](repeating: 0x22, count: 32))
        defer { try? FileManager.default.removeItem(at: url) }
        pane.setSelection(SelectionModel(start: 0, end: 0x10, fileSize: 32))

        let controller = MainViewController()
        let menu = controller.makeOffsetMenu(for: pane, offset: 0x04)
        let copyItem = try XCTUnwrap(menu.items.first { $0.title == "Copy" })

        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedString { pasteboard.setString(savedString, forType: .string) }
        }
        let dispatched = NSApp.sendAction(copyItem.action!, to: copyItem.target, from: copyItem)
        XCTAssertTrue(dispatched, "the context Copy must dispatch")
        XCTAssertEqual(pasteboard.string(forType: .string),
                       "22222222222222222222222222222222",
                       "the clipboard must hold the right-clicked pane's selection bytes")
    }
}
