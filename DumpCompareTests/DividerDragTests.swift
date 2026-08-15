import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the divider is draggable by the mouse. NSSplitView's built-in drag
/// can't be used — it fights the proportional layout and snaps the divider
/// back on mouse-up — so ProportionalSplitView handles the drag itself.
/// These tests drive that drag with synthesized mouse events.
///
/// A real window is used (not just a bare container): the drag reads
/// `event.locationInWindow`, and without a window AppKit's window-coordinate
/// conversion flips the y-axis, which would silently invert a stacked drag.
@MainActor
final class DividerDragTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// Builds a ComparisonView pinned into a real window. Points returned are
    /// in the split view's own coordinates; `windowPoint` converts them for the
    /// synthesized events.
    private func makeComparisonView(vertical: Bool) throws -> (ComparisonView, NSWindow) {
        UserDefaults.standard.set(vertical, forKey: "ComparisonPaneLayoutIsVertical")
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let p1 = PaneViewModel()
        let p2 = PaneViewModel()
        try p1.open(url: url1)
        try p2.open(url: url2)
        let coordinator = ComparisonCoordinator { () -> (left: ByteStorage, right: ByteStorage)? in
            guard let l = p1.byteStorage, let r = p2.byteStorage else { return nil }
            return (l, r)
        }
        let cv = ComparisonView(coordinator: coordinator, paneView1: FilePaneView(viewModel: p1), paneView2: FilePaneView(viewModel: p2))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        cv.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            cv.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            cv.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return (cv, window)
    }

    private func windowPoint(_ splitView: NSSplitView, _ point: NSPoint) -> NSPoint {
        splitView.convert(point, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    /// Drags the divider from its current spot to `target` (both in the split
    /// view's coordinates).
    private func drag(splitView sv: NSSplitView, to target: NSPoint, window: NSWindow) {
        let start = NSPoint(x: sv.arrangedSubviews[0].frame.maxX, y: sv.arrangedSubviews[0].frame.midY)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, start), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, target), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, target), window: window))
    }

    func testDividerDragMovesToMousePositionAndPersists() throws {
        let (cv, window) = try makeComparisonView(vertical: true)
        let dividerX = cv.paneView1.frame.maxX

        // Mouse down on the divider, drag +200pt, release.
        drag(splitView: cv.splitView, to: NSPoint(x: dividerX + 200, y: 300), window: window)

        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width
        let available = 1200 - cv.splitView.dividerThickness
        XCTAssertEqual(w1, available / 2 + 200, accuracy: 1)
        XCTAssertEqual(w2, available / 2 - 200, accuracy: 1)
        XCTAssertEqual(w1 / (w1 + w2), 0.667, accuracy: 0.01)
    }

    func testDividerDragContinuesOnIncrementalTicks() throws {
        let (cv, window) = try makeComparisonView(vertical: true)
        let sv = cv.splitView
        let dividerX = cv.paneView1.frame.maxX

        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: dividerX, y: 300)), window: window))
        // Two separate drag ticks, like a real mouse moving across several events.
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, NSPoint(x: dividerX + 200, y: 300)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, NSPoint(x: dividerX + 300, y: 300)), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, NSPoint(x: dividerX + 300, y: 300)), window: window))

        let available = 1200 - cv.splitView.dividerThickness
        XCTAssertEqual(cv.paneView1.frame.width, available / 2 + 300, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.width, available / 2 - 300, accuracy: 1)
    }

    func testDividerDragWorksBothDirections() throws {
        let (cv, window) = try makeComparisonView(vertical: true)

        // Drag the divider far left, to a 20% / 80% split.
        drag(splitView: cv.splitView, to: NSPoint(x: 240, y: 300), window: window)

        let available = 1200 - cv.splitView.dividerThickness
        XCTAssertEqual(cv.paneView1.frame.width, 240, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.width, available - 240, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width / available, 0.2, accuracy: 0.01)
    }

    func testDividerDragIsClampedToTheSplitBounds() throws {
        let (cv, window) = try makeComparisonView(vertical: true)
        let dividerX = cv.paneView1.frame.maxX

        // Drag far beyond the right edge: the first pane may not exceed the
        // available width, and the second pane must not go negative.
        drag(splitView: cv.splitView, to: NSPoint(x: dividerX + 5000, y: 300), window: window)

        XCTAssertEqual(cv.paneView1.frame.width, 1200 - cv.splitView.dividerThickness, accuracy: 1)
        XCTAssertEqual(cv.paneView2.frame.width, 0, accuracy: 1)
    }

    func testResizeAfterDragKeepsTheDraggedRatio() throws {
        let (cv, window) = try makeComparisonView(vertical: true)

        drag(splitView: cv.splitView, to: NSPoint(x: 840, y: 300), window: window)
        let ratioBefore = cv.paneView1.frame.width / (cv.paneView1.frame.width + cv.paneView2.frame.width)
        XCTAssertEqual(ratioBefore, 0.7, accuracy: 0.01)

        window.setContentSize(NSSize(width: 1500, height: 600))
        window.layoutIfNeeded()

        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width
        XCTAssertEqual(w1 / (w1 + w2), ratioBefore, accuracy: 0.01)
        let available = 1500 - cv.splitView.dividerThickness
        XCTAssertEqual(w1, ratioBefore * available, accuracy: 1)
        XCTAssertEqual(w2, (1 - ratioBefore) * available, accuracy: 1)
    }

    func testStackedDividerDrag() throws {
        let (cv, window) = try makeComparisonView(vertical: false)
        let sv = cv.splitView
        // First pane sits on top (the split view is flipped, so its bottom edge
        // is maxY); a drag upward — smaller y — shrinks it.
        let dividerY = cv.paneView1.frame.maxY
        let down = NSPoint(x: 400, y: dividerY - 200)

        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: 400, y: dividerY)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, down), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, down), window: window))

        let h1 = cv.paneView1.frame.height
        let h2 = cv.paneView2.frame.height
        let available = 600 - cv.splitView.dividerThickness
        XCTAssertEqual(h1, available / 2 - 200, accuracy: 1)
        XCTAssertEqual(h2, available / 2 + 200, accuracy: 1)
        XCTAssertEqual(h1 + h2, available, accuracy: 1)
    }

    /// A double-click on the divider resets it to a 50/50 split in both
    /// orientations (§3.3), replacing NSSplitView's collapse behavior.
    private func doubleClick(splitView sv: NSSplitView, at p: NSPoint, window: NSWindow) {
        sv.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, clickCount: 1))
        sv.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, clickCount: 1))
        sv.mouseDown(with: mouse(.leftMouseDown, at: p, window: window, clickCount: 2))
        sv.mouseUp(with: mouse(.leftMouseUp, at: p, window: window, clickCount: 2))
        // Let the 0.2s reset animation finish before asserting.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }

    func testDoubleClickDividerResetsToHalfVertical() throws {
        let (cv, window) = try makeComparisonView(vertical: true)
        let sv = cv.splitView

        drag(splitView: sv, to: NSPoint(x: 360, y: 300), window: window)
        XCTAssertEqual(cv.paneView1.frame.width / (cv.paneView1.frame.width + cv.paneView2.frame.width), 0.3, accuracy: 0.01)

        doubleClick(splitView: sv, at: windowPoint(sv, NSPoint(x: cv.paneView1.frame.maxX, y: 300)), window: window)

        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width
        XCTAssertEqual(w1 / (w1 + w2), 0.5, accuracy: 0.01)
        let available = 1200 - cv.splitView.dividerThickness
        XCTAssertEqual(w1, available / 2, accuracy: 1)
        XCTAssertEqual(w2, available / 2, accuracy: 1)
    }

    func testDoubleClickDividerResetsToHalfStacked() throws {
        let (cv, window) = try makeComparisonView(vertical: false)
        let sv = cv.splitView

        // Drag downward (grows the top pane in flipped coordinates) to 0.75.
        let dividerY = cv.paneView1.frame.maxY
        let target = NSPoint(x: 400, y: dividerY + 150)
        sv.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(sv, NSPoint(x: 400, y: dividerY)), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(sv, target), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(sv, target), window: window))
        let before = cv.paneView1.frame.height / (cv.paneView1.frame.height + cv.paneView2.frame.height)
        XCTAssertEqual(before, 0.75, accuracy: 0.01)

        doubleClick(splitView: sv, at: windowPoint(sv, NSPoint(x: 400, y: cv.paneView1.frame.maxY)), window: window)

        let h1 = cv.paneView1.frame.height
        let h2 = cv.paneView2.frame.height
        XCTAssertEqual(h1 / (h1 + h2), 0.5, accuracy: 0.01)
        let available = 600 - cv.splitView.dividerThickness
        XCTAssertEqual(h1, available / 2, accuracy: 1)
        XCTAssertEqual(h2, available / 2, accuracy: 1)
    }
}
