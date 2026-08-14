import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §3.3: the two comparison panes must always split the window 50/50.
/// NSSplitView's default redistribution hands the entire resize delta to one
/// pane and holds the other; the equal-size constraints in ComparisonView force
/// both panes to share every resize (width side-by-side, height stacked).
@MainActor
final class ComparisonResizeTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resize-test-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func makeComparisonView(vertical: Bool) throws -> (ComparisonView, PaneViewModel, PaneViewModel) {
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
        return (cv, p1, p2)
    }

    func testSideBySideSharesWidthResizeEqually() throws {
        let (cv, _, _) = try makeComparisonView(vertical: true)
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

        // 50/50 at any width (the 1 pt divider may cost one pane a point).
        XCTAssertEqual(abs(cv.paneView1.frame.width - cv.paneView2.frame.width), 1, accuracy: 1)
        let w1 = cv.paneView1.frame.width
        let w2 = cv.paneView2.frame.width

        container.setFrameSize(NSSize(width: 1500, height: 600))
        container.layoutSubtreeIfNeeded()

        // Both panes must absorb the same share of the width delta.
        XCTAssertEqual(cv.paneView1.frame.width - w1, cv.paneView2.frame.width - w2, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.width, cv.paneView2.frame.width, accuracy: 1)
    }

    func testStackedSharesHeightResizeEqually() throws {
        let (cv, _, _) = try makeComparisonView(vertical: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200))
        cv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cv)
        NSLayoutConstraint.activate([
            cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cv.topAnchor.constraint(equalTo: container.topAnchor),
            cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(abs(cv.paneView1.frame.height - cv.paneView2.frame.height), 1, accuracy: 1)
        let h1 = cv.paneView1.frame.height
        let h2 = cv.paneView2.frame.height

        container.setFrameSize(NSSize(width: 800, height: 1500))
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(cv.paneView1.frame.height - h1, cv.paneView2.frame.height - h2, accuracy: 1)
        XCTAssertEqual(cv.paneView1.frame.height, cv.paneView2.frame.height, accuracy: 1)
    }
}
