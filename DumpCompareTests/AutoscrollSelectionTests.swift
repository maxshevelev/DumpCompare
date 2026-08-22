import DumpCompareCore
import XCTest
@testable import DumpCompare

/// Drag-selection autoscroll (§6): when a drag selection is pushed beyond the
/// visible top or bottom edge of the pane, the pane scrolls so the selection
/// can keep extending in that direction — the classic text-editor behaviour.
/// The scroll is driven by the pointer's position past the edge, and continues
/// (via a repeating timer) while the pointer is held there; the selection end
/// clamps to the visible edge, so it always tracks the row at the edge.
@MainActor
final class AutoscrollSelectionTests: XCTestCase {
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

    /// A point over a hex byte whose view-coordinate y is `dy` relative to the
    /// given baseline. Positive `dy` pushes below the baseline (toward EOF),
    /// negative above it.
    private func bytePoint(_ hexView: HexView, atY y: CGFloat) -> NSPoint {
        let layout = hexView.hexLayout
        let local = CGPoint(x: layout.hexByteX(column: 0) + layout.charWidth, y: y)
        return hexView.convert(local, to: nil)
    }

    private func scroll(_ hexView: HexView) -> NSScrollView {
        hexView.enclosingScrollView!
    }

    // MARK: - Scrolling down past the bottom edge

    /// Dragging below the visible bottom edge scrolls the pane down so the
    /// selection extends past the rows that were visible when the drag began.
    func testDragBelowBottomEdgeScrollsDownAndExtendsSelection() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        let layout = hexView.hexLayout
        let visibleHeight = clip.bounds.height
        XCTAssertGreaterThan(hexView.hexContentHeight, visibleHeight, "the file must overflow the viewport")

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        XCTAssertEqual(clip.bounds.origin.y, 0)

        let below = bytePoint(hexView, atY: visibleHeight + 100)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: below, window: window))
        hexView.mouseUp(with: mouse(.leftMouseUp, at: below, window: window))

        XCTAssertGreaterThan(clip.bounds.origin.y, 0, "the pane must scroll down to follow the pointer")
        let bottomRow = Int(visibleHeight / layout.rowHeight)
        XCTAssertGreaterThan(pane.hexSelection().end, UInt64(bottomRow * 16),
                             "the selection must extend past the originally visible bottom row")
    }

    /// A drag that stays inside the visible area never scrolls — autoscroll is
    /// only for pointers pushed past the edge.
    func testDragInsidePaneDoesNotScroll() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: byteCentre(hexView, row: 5, column: 3), window: window))
        hexView.mouseUp(with: mouse(.leftMouseUp, at: byteCentre(hexView, row: 5, column: 3), window: window))

        XCTAssertEqual(clip.bounds.origin.y, 0, "an in-pane drag must not scroll")
        XCTAssertEqual(pane.hexSelection().end, 5 * 16 + 4)
    }

    /// The reported freeze: with the pointer held still just past the pane's
    /// edge, the pane scrolled once and stopped. Both geometries it happened at
    /// are checked here — a small overshoot below the scroll view, and the
    /// status bar, which is inside the window but outside the scroll view — and
    /// each is held for half a second, so the test pays one second in total
    /// rather than two.
    ///
    /// The overshoot is deliberately small (20 pt, and the status bar is 12 pt):
    /// the bug was specific to small overshoots, where the old pre-scroll check
    /// outran the step. A large overshoot masked it.
    func testAutoscrollKeepsGoingWhileThePointerIsHeldStillPastTheEdge() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let scroll = scroll(hexView)
        let clip = scroll.contentView
        let tracking = RunLoop.Mode(rawValue: "kCFRunLoopEventTrackingMode")
        /// Half a second of event-tracking run loop — where the autoscroll timer
        /// is registered — with no further drag events.
        func holdStill() {
            for _ in 0..<10 {
                RunLoop.main.run(mode: tracking, before: Date().addingTimeInterval(0.05))
            }
        }

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))

        // Phase 1: just past the scroll view's bottom edge.
        let pastEdge = bytePoint(hexView, atY: clip.bounds.height + 20)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: pastEdge, window: window))
        let afterFirstDrag = clip.bounds.origin.y
        XCTAssertGreaterThan(afterFirstDrag, 0, "the drag past the edge must scroll the pane")
        holdStill()
        let afterFirstHold = clip.bounds.origin.y
        XCTAssertGreaterThan(afterFirstHold, afterFirstDrag + 100,
                             "held still past the edge, the pane must keep scrolling — one step would stop here")

        // Phase 2: the status bar, inside the window but outside the scroll
        // view — the point the bug was reported at.
        let scrollWindowFrame = scroll.convert(scroll.bounds, to: nil)
        let statusPoint = NSPoint(x: scrollWindowFrame.midX, y: scrollWindowFrame.minY - 12)
        XCTAssertGreaterThan(statusPoint.y, 0, "premise: the status-bar point is inside the window")
        XCTAssertLessThan(statusPoint.y, window.frame.height, "premise: and not below it")
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: statusPoint, window: window))
        holdStill()
        XCTAssertGreaterThan(clip.bounds.origin.y, afterFirstHold + 100,
                             "and it keeps scrolling with the pointer on the status bar too")

        XCTAssertGreaterThan(pane.hexSelection().end, 0,
                             "the selection extends all the while, without any mouse movement")
        hexView.mouseUp(with: mouse(.leftMouseUp, at: statusPoint, window: window))
    }

    // MARK: - Scrolling up past the top edge

    /// Dragging above the visible top edge scrolls the pane up and extends the
    /// selection backward, past the rows that were visible at the drag start.
    func testDragAboveTopEdgeScrollsUpAndExtendsSelectionBackward() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let scrollView = scroll(hexView)
        let clip = scrollView.contentView
        let layout = hexView.hexLayout
        // Park the pane at the bottom of the document so there is room above.
        let maxScroll = max(0, hexView.hexContentHeight - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: 0, y: maxScroll))
        scrollView.reflectScrolledClipView(clip)
        let topRowStart = UInt64(Int(clip.bounds.minY / layout.rowHeight) * 16)

        hexView.mouseDown(with: mouse(.leftMouseDown,
                                      at: byteCentre(hexView, row: Int(clip.bounds.minY / layout.rowHeight), column: 0),
                                      window: window))
        let above = bytePoint(hexView, atY: clip.bounds.minY - 100)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: above, window: window))
        hexView.mouseUp(with: mouse(.leftMouseUp, at: above, window: window))

        XCTAssertLessThan(clip.bounds.origin.y, maxScroll, "the pane must scroll up to follow the pointer")
        let sel = pane.hexSelection()
        XCTAssertLessThan(sel.start, topRowStart,
                          "the selection must extend above the originally visible top row")
    }

    /// Dragging above the top edge while already at the top of the document
    /// scrolls nowhere — the document has no rows above to reveal — and the
    /// selection clamps to the visible top edge, i.e. the first byte.
    func testDragAboveTopAtDocumentStartClampsToTopRow() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        let above = bytePoint(hexView, atY: -50)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: above, window: window))
        hexView.mouseUp(with: mouse(.leftMouseUp, at: above, window: window))

        XCTAssertEqual(clip.bounds.origin.y, 0, "there is nothing to scroll to above the document start")
        XCTAssertEqual(pane.hexSelection().start, 0)
        XCTAssertEqual(pane.hexSelection().end, 1, "the selection clamps to the first byte")
    }

    // MARK: - Continuous scroll while the pointer is held past the edge

    /// While the pointer is held beyond the bottom edge, the autoscroll timer
    /// keeps scrolling and extending the selection on each tick — the pointer
    /// sits at a fixed spot on screen while the document scrolls under it.
    func testAutoscrollTickKeepsScrollingAndSelecting() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        let visibleHeight = clip.bounds.height

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        let below = bytePoint(hexView, atY: visibleHeight + 100)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: below, window: window))

        let originAfterDrag = clip.bounds.origin.y
        let endAfterDrag = pane.hexSelection().end
        XCTAssertGreaterThan(originAfterDrag, 0)

        // Drive several timer ticks synchronously — the run loop never spins in
        // a unit test, so the scheduled timer wouldn't fire on its own.
        for _ in 0..<5 {
            hexView.performDragAutoscrollTick()
        }

        XCTAssertGreaterThan(clip.bounds.origin.y, originAfterDrag,
                             "each tick must keep scrolling toward the held pointer")
        XCTAssertGreaterThan(pane.hexSelection().end, endAfterDrag,
                             "the selection must keep extending to the row at the edge")
        hexView.mouseUp(with: mouse(.leftMouseUp, at: below, window: window))
    }

    /// The scroll speed is linear in the overshoot, as in HexFiend: each step
    /// scrolls exactly the distance the pointer sits past the edge, so the
    /// speed grows in lockstep with the overshoot — a barely-past-edge pointer
    /// creeps, a far-out one glides fast, with no saturation and no flat band
    /// near the edge.
    func testAutoscrollSpeedRisesSmoothlyWithOvershoot() throws {
        let (_, _, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 8192))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        XCTAssertGreaterThan(hexView.hexContentHeight, clip.bounds.height)

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))

        var increments: [CGFloat] = []
        for overshoot: CGFloat in [8, 16, 32] {
            let before = clip.bounds.origin.y
            let beyond = bytePoint(hexView, atY: clip.bounds.maxY + overshoot)
            hexView.mouseDragged(with: mouse(.leftMouseDragged, at: beyond, window: window))
            increments.append(clip.bounds.origin.y - before)
        }
        hexView.mouseUp(with: mouse(.leftMouseUp, at: bytePoint(hexView, atY: clip.bounds.maxY), window: window))

        XCTAssertEqual(increments.count, 3)
        XCTAssertGreaterThan(increments[0], 0, "even a small overshoot must scroll")
        XCTAssertGreaterThan(increments[1], increments[0],
                             "speed must grow as the pointer moves further past the edge")
        XCTAssertGreaterThan(increments[2], increments[1],
                             "speed must keep growing with the overshoot")
    }

    /// The autoscroll timer stops once the document has fully scrolled to the
    /// bottom — the pane cannot scroll further, so the selection settles.
    func testAutoscrollTickStopsAtDocumentEnd() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        let visibleHeight = clip.bounds.height
        let maxScroll = max(0, hexView.hexContentHeight - visibleHeight)

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        // Push the pointer far below the edge and let the timer run it to the
        // bottom of the document.
        let below = bytePoint(hexView, atY: visibleHeight + 4000)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: below, window: window))

        var lastOrigin = clip.bounds.origin.y
        for _ in 0..<500 {
            hexView.performDragAutoscrollTick()
            let origin = clip.bounds.origin.y
            if origin == lastOrigin { break }
            lastOrigin = origin
        }

        XCTAssertEqual(clip.bounds.origin.y, maxScroll, "the pane must come to rest at the document's bottom edge")
        XCTAssertEqual(pane.hexSelection().end, 4096, "the selection must settle at EOF")
        hexView.mouseUp(with: mouse(.leftMouseUp, at: below, window: window))
    }
}
