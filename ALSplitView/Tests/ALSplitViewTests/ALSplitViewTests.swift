import Cocoa
import XCTest
@testable import ALSplitView

/// Unit tests for `ALSplitView`: the layout policy math, the divider drag
/// (driven with synthesized mouse events in a real window, like the app's
/// own divider tests), the clamping, and the collapse-to-zero behaviour.
@MainActor
final class ALSplitViewTests: XCTestCase {
    /// Builds a split view pinned into a real window. A real window is used
    /// (not just a bare container): the drag reads `event.locationInWindow`,
    /// and without a window AppKit's window-coordinate conversion flips the
    /// y-axis, which would silently invert a stacked drag.
    private func makeSplit(isVertical: Bool, width: CGFloat = 1000, height: CGFloat = 600,
                           paneCount: Int = 2) -> (ALSplitView, NSWindow) {
        let split = ALSplitView()
        split.isVertical = isVertical
        for _ in 0..<paneCount {
            split.addPane(NSView())
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        split.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            split.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            split.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()
        return (split, window)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow,
                       clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    /// Converts a point in the split view's (flipped) coordinates to window
    /// coordinates for the synthesized events — the view is flipped, so a
    /// raw pass-through would silently invert a stacked drag.
    private func windowPoint(_ split: ALSplitView, _ point: NSPoint) -> NSPoint {
        split.convert(point, to: nil)
    }

    /// Drags divider `index` from its current spot to `target` (both in the
    /// split view's coordinates).
    private func drag(_ split: ALSplitView, divider index: Int, to target: NSPoint, window: NSWindow) {
        let position = split.dividerPosition(at: index) + split.dividerThickness / 2
        // The grab point sits on the divider's strip: its centre along the
        // axis, the bounds' middle across it.
        let start = split.isVertical
            ? NSPoint(x: position, y: split.bounds.midY)
            : NSPoint(x: split.bounds.midX, y: position)
        split.mouseDown(with: mouse(.leftMouseDown, at: windowPoint(split, start), window: window))
        split.mouseDragged(with: mouse(.leftMouseDragged, at: windowPoint(split, target), window: window))
        split.mouseUp(with: mouse(.leftMouseUp, at: windowPoint(split, target), window: window))
        window.layoutIfNeeded()
    }

    // MARK: - Layout policy

    func testProportionalAndFillSplitTheAxis() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        split.layout()

        let available = 1000 - split.dividerThickness
        XCTAssertEqual(split.panes[0].frame.width, available / 2, accuracy: 0.5)
        XCTAssertEqual(split.panes[1].frame.width, available / 2, accuracy: 0.5)
        XCTAssertEqual(split.panes[0].frame.maxX + split.dividerThickness,
                       split.panes[1].frame.minX, accuracy: 0.01)
    }

    func testFixedPaneKeepsItsSizeAcrossResizes() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(200), at: 1)
        split.layout()

        XCTAssertEqual(split.panes[1].frame.width, 200, accuracy: 0.5)
        XCTAssertEqual(split.panes[0].frame.width, 1000 - 200 - split.dividerThickness, accuracy: 0.5)

        window.setContentSize(NSSize(width: 1400, height: 600))
        window.layoutIfNeeded()

        XCTAssertEqual(split.panes[1].frame.width, 200, accuracy: 0.5,
                       "the fixed pane keeps its size; the fill pane absorbs the delta")
        XCTAssertEqual(split.panes[0].frame.width, 1400 - 200 - split.dividerThickness, accuracy: 0.5)
    }

    func testProportionalPairKeepsItsRatioAcrossResizes() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.7), at: 0)
        split.setPaneLayout(.fill, at: 1)
        split.layout()

        window.setContentSize(NSSize(width: 1300, height: 600))
        window.layoutIfNeeded()

        let available = 1300 - split.dividerThickness
        XCTAssertEqual(split.panes[0].frame.width, 0.7 * available, accuracy: 0.5)
        XCTAssertEqual(split.panes[1].frame.width, 0.3 * available, accuracy: 0.5)
    }

    func testStackedLayoutPutsTheFirstPaneOnTop() {
        let (split, _) = makeSplit(isVertical: false)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        split.layout()

        let available = 600 - split.dividerThickness
        XCTAssertEqual(split.panes[0].frame.minY, 0, accuracy: 0.01,
                       "flipped coordinates: the first pane sits at the top")
        XCTAssertEqual(split.panes[0].frame.height, available / 2, accuracy: 0.5)
        XCTAssertEqual(split.panes[1].frame.minY, available / 2 + split.dividerThickness, accuracy: 0.5)
    }

    // MARK: - Divider position and clamping

    func testSetDividerPositionClampsToTheAxis() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)

        split.setDividerPosition(10_000)
        let available = split.axisAvailable()
        XCTAssertEqual(split.dividerPosition(at: 0), available, accuracy: 0.5,
                       "a position past the edge clamps to the full axis")
        XCTAssertEqual(split.panes[1].frame.width, 0, accuracy: 0.01)

        split.setDividerPosition(-10_000)
        XCTAssertEqual(split.dividerPosition(at: 0), 0, accuracy: 0.01)
        XCTAssertEqual(split.panes[0].frame.width, 0, accuracy: 0.01)
    }

    func testConsumerClampWinsOverTheAxis() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(300), at: 1)
        // Keep both panes at least 100 wide.
        split.clampDividerPosition = { _, position in
            min(max(position, 100), split.axisAvailable() - 100)
        }

        split.setDividerPosition(10)
        XCTAssertEqual(split.dividerPosition(at: 0), 100, accuracy: 0.5)

        split.setDividerPosition(10_000)
        XCTAssertEqual(split.dividerPosition(at: 0), split.axisAvailable() - 100, accuracy: 0.5)
    }

    func testDividerMoveFiresTheCallback() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        var moved: [(Int, CGFloat)] = []
        split.onDividerMoved = { index, position in moved.append((index, position)) }

        split.setDividerPosition(250)

        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].0, 0)
        XCTAssertEqual(moved[0].1, 250, accuracy: 0.5)
    }

    // MARK: - Drag

    func testDragMovesTheDividerOneToOne() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        let start = split.dividerPosition(at: 0)

        drag(split, divider: 0, to: NSPoint(x: start + 200, y: 300), window: window)

        XCTAssertEqual(split.dividerPosition(at: 0), start + 200, accuracy: 1)
        // The drag rewrote the proportional policy, so the ratio survives a
        // resize.
        let ratio = split.dividerPosition(at: 0) / split.axisAvailable()
        window.setContentSize(NSSize(width: 1200, height: 600))
        window.layoutIfNeeded()
        XCTAssertEqual(split.dividerPosition(at: 0) / split.axisAvailable(), ratio, accuracy: 0.01)
    }

    func testDragClampsToTheAxis() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)

        drag(split, divider: 0, to: NSPoint(x: 100_000, y: 300), window: window)

        XCTAssertEqual(split.dividerPosition(at: 0), split.axisAvailable(), accuracy: 0.5)
        XCTAssertEqual(split.panes[1].frame.width, 0, accuracy: 0.01,
                       "a pane dragged to the edge is zero — nothing balloons")
    }

    func testStackedDragMovesTheDividerVertically() {
        let (split, window) = makeSplit(isVertical: false)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        let start = split.dividerPosition(at: 0)

        drag(split, divider: 0, to: NSPoint(x: 400, y: start - 100), window: window)

        XCTAssertEqual(split.dividerPosition(at: 0), start - 100, accuracy: 1)
    }

    func testDoubleClickFiresTheCallback() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        var doubleClicked: [Int] = []
        split.onDividerDoubleClicked = { doubleClicked.append($0) }

        let point = windowPoint(split, NSPoint(x: split.dividerPosition(at: 0) + split.dividerThickness / 2, y: 300))
        split.mouseDown(with: mouse(.leftMouseDown, at: point, window: window, clickCount: 1))
        split.mouseUp(with: mouse(.leftMouseUp, at: point, window: window, clickCount: 1))
        split.mouseDown(with: mouse(.leftMouseDown, at: point, window: window, clickCount: 2))
        split.mouseUp(with: mouse(.leftMouseUp, at: point, window: window, clickCount: 2))

        XCTAssertEqual(doubleClicked, [0])
    }

    func testClickAwayFromTheDividerDoesNothing() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        let before = split.dividerPosition(at: 0)

        // A press deep inside the first pane, then a drag: no divider move.
        split.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 50, y: 300), window: window))
        split.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 250, y: 300), window: window))
        split.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 250, y: 300), window: window))

        XCTAssertEqual(split.dividerPosition(at: 0), before, accuracy: 0.01)
    }

    // MARK: - Collapse

    func testFixedZeroCollapsesThePane() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(0), at: 1)
        split.layout()

        XCTAssertEqual(split.panes[1].frame.width, 0, accuracy: 0.01)
        XCTAssertEqual(split.panes[0].frame.width, split.axisAvailable(), accuracy: 0.5)
    }

    // MARK: - Animation

    func testAnimateDividerPositionEasesToTheTarget() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.proportional(0.5), at: 0)
        split.setPaneLayout(.fill, at: 1)
        let target = split.axisAvailable() - 100

        split.animateDividerPosition(to: target, duration: 0.1)
        // Let the 0.1s animation finish.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertFalse(split.isAnimatingDivider)
        XCTAssertEqual(split.dividerPosition(at: 0), target, accuracy: 1)
    }

    /// The size animation eases the pane's size, not the divider's position, so
    /// a split view resized mid-animation still lands the pane at the target —
    /// the minimap's show grows the window by the panel's width at the same
    /// moment the panel glides in.
    func testAnimateTrailingPaneSizeTracksLiveBounds() {
        let (split, window) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(0), at: 1)
        let target: CGFloat = 200

        split.animateTrailingPaneSize(to: target, duration: 0.1)
        // Resize the window mid-animation.
        window.setContentSize(NSSize(width: 1400, height: 600))
        window.layoutIfNeeded()
        // Let the animation finish.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertFalse(split.isAnimatingDivider)
        XCTAssertEqual(split.panes[1].frame.width, target, accuracy: 1,
                       "the pane lands at the target size despite the mid-animation resize")
    }

    /// The animation's tick hook reports eased progress, ending at 1 — so a
    /// consumer can move something of its own (the enclosing window, say) on
    /// this animation's clock instead of starting a second one beside it.
    func testTrailingPaneSizeAnimationReportsProgressEndingAtOne() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "reduced motion skips the animation; the skip path is covered below")
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(0), at: 1)

        var progress: [CGFloat] = []
        split.animateTrailingPaneSize(to: 200, duration: 0.1) { progress.append($0) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertGreaterThan(progress.count, 2, "the hook runs per frame, not once")
        XCTAssertEqual(progress.first ?? -1, 0, accuracy: 0.05, "it starts where the pane is")
        XCTAssertEqual(progress.last ?? -1, 1, accuracy: 0.001, "and ends exactly at the target")
        XCTAssertEqual(progress, progress.sorted(), "progress only moves forward")
    }

    /// The hook is still called with 1 when the animation is skipped — a
    /// distance too small to be worth easing. A consumer that moves with the
    /// animation must not be left half-way just because the split decided it
    /// had nothing to animate.
    func testTrailingPaneSizeAnimationReportsCompletionWhenItSkips() {
        let (split, _) = makeSplit(isVertical: true)
        split.setPaneLayout(.fill, at: 0)
        split.setPaneLayout(.fixed(200), at: 1)

        var progress: [CGFloat] = []
        // Already there, so there is nothing to ease.
        split.animateTrailingPaneSize(to: 200, duration: 0.1) { progress.append($0) }

        XCTAssertFalse(split.isAnimatingDivider)
        XCTAssertEqual(progress, [1], "the skip path still reports completion")
    }

    /// A pane's constraint-based content stretches to the frame the split
    /// gives the pane — in the very same layout pass, with no second
    /// `layoutIfNeeded()`.
    ///
    /// This is the regression that made a freshly opened second panel leave a
    /// blank region where the first panel should be. A pane whose
    /// `translatesAutoresizingMaskIntoConstraints` is off and which carries no
    /// constraints has its geometry owned by the layout engine, not by its
    /// frame: `layout()` sets the frame, the engine never hears about it, and
    /// a view pinned to the pane's edges keeps whatever stale size the engine
    /// last solved — a correctly sized pane holding under-sized content.
    /// Panes are frame-based (`addPane`) precisely so the frame reaches the
    /// engine and the pins are solved against it.
    func testPaneContentStretchesToThePaneFrameInOnePass() {
        let split = ALSplitView()
        split.isVertical = true
        // Each pane wraps a child pinned to its four edges — the app's
        // pane-wrapper shape (a drop-band overlay around a file pane).
        var children: [NSView] = []
        for _ in 0..<2 {
            let pane = NSView()
            let child = NSView()
            child.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                child.topAnchor.constraint(equalTo: pane.topAnchor),
                child.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            ])
            split.addPane(pane)
            children.append(child)
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        split.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            split.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            split.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])
        window.layoutIfNeeded()

        for (i, child) in children.enumerated() {
            XCTAssertEqual(child.frame.width, split.panes[i].frame.width, accuracy: 0.01,
                           "pane \(i)'s content fills the pane's width, leaving no blank region")
            XCTAssertEqual(child.frame.height, split.panes[i].frame.height, accuracy: 0.01,
                           "pane \(i)'s content fills the pane's height")
        }
        XCTAssertEqual(children[0].frame.width, children[1].frame.width, accuracy: 0.01,
                       "the two panes' content is evenly split")
        XCTAssertGreaterThan(children[0].frame.width, 0)
    }
}
