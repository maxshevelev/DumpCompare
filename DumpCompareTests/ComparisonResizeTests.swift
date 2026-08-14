import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the two comparison panes split 50/50 by default (fresh comparison),
/// the divider can be dragged to any ratio, and window resizes preserve that
/// ratio proportionally instead of handing the whole delta to one pane.
@MainActor
final class ComparisonResizeTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resize-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func makeComparisonView(vertical: Bool) throws -> (ComparisonView, NSView) {
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        cv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return (cv, container)
    }

    func testDefaultSplitIsEven() throws {
        let (cv, _) = try makeComparisonView(vertical: true)

        XCTAssertEqual(cv.paneView1.frame.width, cv.paneView2.frame.width, accuracy: 1)
    }

    func testDividerIsDraggableToCustomRatio() throws {
        let (cv, _) = try makeComparisonView(vertical: true)

        // Drag the divider to 70% / 30%.
        cv.splitView.setPosition(840, ofDividerAt: 0)
        cv.layoutSubtreeIfNeeded()

        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width
        XCTAssertEqual(w1 / (w1 + w2), 0.7, accuracy: 0.01)
        XCTAssertEqual(w1 + w2, 1199, accuracy: 1)  // 1200 − 1 pt divider
    }

    func testResizeKeepsDraggedRatio() throws {
        let (cv, container) = try makeComparisonView(vertical: true)

        // Drag to 70/30, then resize the window wider: the ratio must persist.
        cv.splitView.setPosition(840, ofDividerAt: 0)
        cv.layoutSubtreeIfNeeded()
        let ratioBefore = cv.paneView1.frame.width / (cv.paneView1.frame.width + cv.paneView2.frame.width)

        container.setFrameSize(NSSize(width: 1500, height: 600))
        container.layoutSubtreeIfNeeded()

        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width
        XCTAssertEqual(w1 / (w1 + w2), ratioBefore, accuracy: 0.01)
        XCTAssertEqual(w1, 1050, accuracy: 1)   // 70% of 1499
        XCTAssertEqual(w2, 449, accuracy: 1)    // 30% of 1499
    }

    func testStackedResizeKeepsHeightRatio() throws {
        let (cv, container) = try makeComparisonView(vertical: false)

        // Drag the horizontal divider to ~70/30 of the 600pt height (420pt to
        // the top pane), then resize; the ratio must persist proportionally.
        cv.splitView.setPosition(420, ofDividerAt: 0)
        cv.layoutSubtreeIfNeeded()
        let ratioBefore = cv.paneView1.frame.height / (cv.paneView1.frame.height + cv.paneView2.frame.height)
        XCTAssertEqual(ratioBefore, 0.7, accuracy: 0.01)

        container.setFrameSize(NSSize(width: 800, height: 1500))
        container.layoutSubtreeIfNeeded()

        let h1 = cv.paneView1.frame.height
        let h2 = cv.paneView2.frame.height
        XCTAssertEqual(h1 / (h1 + h2), ratioBefore, accuracy: 0.01)
        XCTAssertEqual(h1, ratioBefore * 1499, accuracy: 1)
        XCTAssertEqual(h2, (1 - ratioBefore) * 1499, accuracy: 1)
    }
}
