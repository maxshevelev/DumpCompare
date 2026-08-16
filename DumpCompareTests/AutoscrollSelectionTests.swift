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

    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoscroll-\(UUID().uuidString).bin")
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

    /// Regression for the real-app report "на статус-баре под панелью автоскролл
    /// останавливается": the pane's scroll view sits above a 24px status bar, so a
    /// pointer parked on the bar is past the pane's bottom edge yet still INSIDE
    /// the window. Holding it still there must keep scrolling, exactly as holding
    /// it outside the window does.
    ///
    /// This is the decisive case, and it must scroll far enough to prove the
    /// timer KEEPS going rather than firing once and dying: the old code armed
    /// the timer, scrolled a single step, then saw its own pre-scroll pointer
    /// coordinate now inside the post-scroll viewport and stopped — so the pane
    /// crept ~one step and froze. Holding the pointer for a full second must
    /// move it several viewport heights to rule that out.
    func testAutoscrollContinuesWhilePointerHeldOnStatusBar() throws {
        let (filePane, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let scroll = scroll(hexView)
        let clip = scroll.contentView
        // The status bar is the bottom 24px strip of the pane, below the scroll
        // view. In window coordinates (y up) its point is just under the scroll
        // view's bottom edge.
        let scrollWindowFrame = scroll.convert(scroll.bounds, to: nil)
        let statusPoint = NSPoint(x: scrollWindowFrame.midX, y: scrollWindowFrame.minY - 12)
        XCTAssertGreaterThan(statusPoint.y, 0, "the status-bar point must be inside the window")
        XCTAssertLessThan(statusPoint.y, window.frame.height, "the status-bar point must not be below the window")

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: statusPoint, window: window))

        let originAfterDrag = clip.bounds.origin.y
        XCTAssertGreaterThan(originAfterDrag, 0, "the drag onto the status bar must scroll the pane")

        // Hold the pointer still: run the event-tracking run loop, which must keep
        // firing the autoscroll timer with no new drag events. A full second at
        // ~30 ticks/s with a ~17px step should move the pane far beyond what one
        // frozen tick could produce.
        let tracking = RunLoop.Mode(rawValue: "kCFRunLoopEventTrackingMode")
        for _ in 0..<20 {
            RunLoop.main.run(mode: tracking, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertGreaterThan(clip.bounds.origin.y, originAfterDrag + 200,
                             "holding still on the status bar must keep scrolling far past one step")
        XCTAssertGreaterThan(pane.hexSelection().end, 0)
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

    /// Holding the pointer STILL beyond the edge must keep scrolling — the pane
    /// is driven by a repeating timer, so it advances even though no new
    /// `mouseDragged` events arrive. The timer is registered for both the
    /// event-tracking and the common run-loop modes; the event-tracking mode is
    /// what a unit test can spin, and a live `NSApplication.run` probe confirmed
    /// the real drag loop fires the `.common` registration the same way.
    func testAutoscrollContinuesWhilePointerHeldStillPastEdge() throws {
        let (_, pane, hexView, window, url) = try makePane([UInt8](repeating: 0x11, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        let clip = scroll(hexView).contentView
        let visibleHeight = clip.bounds.height

        hexView.mouseDown(with: mouse(.leftMouseDown, at: byteCentre(hexView, row: 0, column: 0), window: window))
        // A SMALL overshoot (20px) deliberately: the bug's freeze was specific
        // to small overshoots — exactly where the status bar (12px) and a
        // pointer barely past the edge sit. (A large overshoot masked it
        // because the old pre-scroll check was outrun by the bigger step.)
        let below = bytePoint(hexView, atY: visibleHeight + 20)
        hexView.mouseDragged(with: mouse(.leftMouseDragged, at: below, window: window))

        let originAfterDrag = clip.bounds.origin.y
        XCTAssertGreaterThan(originAfterDrag, 0)

        // No further drag events: the pointer is held still beyond the edge.
        // Run the run loop in the event-tracking mode, where the timer is also
        // registered, and verify it keeps firing with no new drag events.
        let tracking = RunLoop.Mode(rawValue: "kCFRunLoopEventTrackingMode")
        for _ in 0..<20 {
            RunLoop.main.run(mode: tracking, before: Date().addingTimeInterval(0.05))
        }

        // A full second of held-still ticks must move the pane far beyond the
        // single step a frozen timer could produce (the old bug scrolled once,
        // then stopped). One ~17px step would leave it near originAfterDrag.
        XCTAssertGreaterThan(clip.bounds.origin.y, originAfterDrag + 200,
                             "the pane must keep scrolling while the pointer is held still past the edge")
        XCTAssertGreaterThan(pane.hexSelection().end, 0,
                             "the selection must keep extending without mouse movement")
        hexView.mouseUp(with: mouse(.leftMouseUp, at: below, window: window))
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
