import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the two comparison panes split 50/50 by default (fresh comparison),
/// the divider can be dragged to any ratio, and window resizes preserve that
/// ratio proportionally instead of handing the whole delta to one pane.
///
/// The ratio is set by the same synthesized divider drag `DividerDragTests`
/// uses, in a real window — `ALSplitView.setDividerPosition` is what the app's
/// own gestures drive, so driving it proves the gesture the app offers.
/// A window (not a bare container) is required: the drag reads
/// `event.locationInWindow`, and without a window AppKit's window-coordinate
/// conversion flips the y-axis, which would silently invert a stacked drag.
@MainActor
final class ComparisonResizeTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

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
        let window = makeTestWindow(width: 1200, height: 600)
        let container = try XCTUnwrap(window.contentView)
        cv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.layoutIfNeeded()
        windows.append(window)
        addTeardownBlock { @MainActor in
            p1.close()
            p2.close()
        }
        return (cv, window)
    }

    /// Drags the horizontal divider to `y` (the split view's own, flipped
    /// coordinates) with synthesized mouse events.
    private func dragStackedDivider(of cv: ComparisonView, to y: CGFloat, window: NSWindow) {
        let sv = cv.splitView
        let start = NSPoint(x: sv.bounds.midX, y: sv.panes[0].frame.maxY)
        let target = NSPoint(x: sv.bounds.midX, y: y)
        sv.mouseDown(with: mouse(.leftMouseDown, at: sv.convert(start, to: nil), window: window))
        sv.mouseDragged(with: mouse(.leftMouseDragged, at: sv.convert(target, to: nil), window: window))
        sv.mouseUp(with: mouse(.leftMouseUp, at: sv.convert(target, to: nil), window: window))
    }

    func testDefaultSplitIsEven() throws {
        let (cv, _) = try makeComparisonView(vertical: true)

        XCTAssertEqual(cv.paneView1.frame.width, cv.paneView2.frame.width, accuracy: 1)
    }

    func testStackedResizeKeepsHeightRatio() throws {
        let (cv, window) = try makeComparisonView(vertical: false)

        // Drag the horizontal divider to 70/30 of the space the two panes share
        // (the 600 pt height less the divider), then resize; the ratio must
        // persist proportionally.
        let sharedBefore = 600 - cv.splitView.dividerThickness
        dragStackedDivider(of: cv, to: 0.7 * sharedBefore, window: window)
        cv.layoutSubtreeIfNeeded()
        XCTAssertEqual(cv.paneView1.frame.height / (cv.paneView1.frame.height + cv.paneView2.frame.height),
                       0.7, accuracy: 0.005, "premise: the drag landed at 70/30")

        window.setContentSize(NSSize(width: 800, height: 1500))
        window.layoutIfNeeded()

        let h1 = cv.paneView1.frame.height
        let h2 = cv.paneView2.frame.height
        XCTAssertEqual(h1 / (h1 + h2), 0.7, accuracy: 0.005)
        let available = 1500 - cv.splitView.dividerThickness
        XCTAssertEqual(h1, 0.7 * available, accuracy: 1)
        XCTAssertEqual(h2, 0.3 * available, accuracy: 1)
    }
}
