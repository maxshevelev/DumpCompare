import DumpCompareCore
import ALSplitView
import XCTest
@testable import DumpCompare

/// Regression test for the pane-reuse path: a pane that starts in
/// single-file mode (inside a `SingleFileDropView` in `contentHost`) is
/// re-parented into a `ComparisonView` when the mode switches to
/// comparison. The split view must lay the re-parented pane out correctly
/// (a 50/50 split) rather than leaving a blank region where it used to be.
@MainActor
final class ReparentPaneReproTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func testReparentedPaneLaysOutCorrectly() throws {
        let url1 = try tempFile([UInt8](repeating: 0x41, count: 4096))
        let url2 = try tempFile([UInt8](repeating: 0x42, count: 512))
        let p1 = PaneViewModel()
        let p2 = PaneViewModel()
        try p1.open(url: url1)
        try p2.open(url: url2)

        let window = makeTestWindow(width: 1200, height: 600)
        let container = try XCTUnwrap(window.contentView)
        windows.append(window)

        // Build the real-app hierarchy: minimapSplit → contentHost.
        let minimapSplit = ALSplitView()
        minimapSplit.translatesAutoresizingMaskIntoConstraints = false
        minimapSplit.isVertical = true
        minimapSplit.dividerThickness = 1
        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        let minimapPanel = NSView()
        minimapPanel.translatesAutoresizingMaskIntoConstraints = false
        minimapSplit.addPane(contentHost)
        minimapSplit.addPane(minimapPanel)
        minimapSplit.setPaneLayout(.fill, at: 0)
        minimapSplit.setPaneLayout(.fixed(0), at: 1)
        container.addSubview(minimapSplit)
        NSLayoutConstraint.activate([
            minimapSplit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            minimapSplit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimapSplit.topAnchor.constraint(equalTo: container.topAnchor),
            minimapSplit.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Phase 1: single-file mode. Pane inside a SingleFileDropView in contentHost.
        let pane1 = FilePaneView(viewModel: p1)
        let dropView = SingleFileDropView(paneView: pane1)
        dropView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(dropView)
        NSLayoutConstraint.activate([
            dropView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            dropView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            dropView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        window.layoutIfNeeded()

        // Phase 2: comparison mode. setContentView swaps in a ComparisonView.
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let coordinator = ComparisonCoordinator { () -> (left: ByteStorage, right: ByteStorage)? in
            guard let l = p1.byteStorage, let r = p2.byteStorage else { return nil }
            return (l, r)
        }
        let pane2 = FilePaneView(viewModel: p2)
        let cv = ComparisonView(coordinator: coordinator, paneView1: pane1, paneView2: pane2)
        cv.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.layoutIfNeeded()

        // The reused pane should be ~half the window width and match the new
        // pane (a 50/50 split), with its scroll view and hex view filling it.
        XCTAssertGreaterThan(cv.paneView1.frame.width, 100,
                             "Reused pane should have a reasonable width")
        XCTAssertEqual(cv.paneView1.frame.width, cv.paneView2.frame.width, accuracy: 1,
                       "Panes should be 50/50")
        XCTAssertEqual(cv.paneView1.scrollView.frame.width, cv.paneView1.frame.width, accuracy: 1,
                       "The scroll view should fill the pane")
        XCTAssertEqual(cv.paneView1.frame.minX, 0, accuracy: 0.01,
                       "The reused pane should sit at the leading edge")

        addTeardownBlock { @MainActor in
            p1.close()
            p2.close()
        }
    }
}
