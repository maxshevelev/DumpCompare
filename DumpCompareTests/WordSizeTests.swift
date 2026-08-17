import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The word-size setting (§6): defaults to one byte, persists, and notifies
/// open hex views to re-lay out so the dump regroups.
@MainActor
final class WordSizeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WordSize.userDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WordSize.userDefaultsKey)
        super.tearDown()
    }

    func testDefaultsToOneByte() {
        XCTAssertEqual(WordSize.current, .one)
    }

    func testSetPersistsAndNotifies() {
        var notified = 0
        // queue: nil delivers synchronously on the posting thread.
        let token = NotificationCenter.default.addObserver(
            forName: WordSize.didChangeNotification, object: nil, queue: nil
        ) { _ in notified += 1 }

        WordSize.set(.four)

        XCTAssertEqual(WordSize.current, .four)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: WordSize.userDefaultsKey), 4)
        XCTAssertEqual(notified, 1)

        NotificationCenter.default.removeObserver(token)
    }

    /// Changing the word size re-lays out an open pane: a word of 8 packs bytes
    /// tighter than one-byte words, so the grid's ideal width shrinks.
    func testSettingWordSizeRegroupsAnOpenPane() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("word-size-\(UUID().uuidString).bin")
        try Data([UInt8](repeating: 0xAB, count: 64)).write(to: url)
        // Sandboxed test host: an undeleted file stays in the app's container.
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = PaneViewModel()
        try vm.open(url: url)
        let pane = FilePaneView(viewModel: vm)
        let oneByteWidth = pane.hexContentWidth

        WordSize.set(.eight)
        // The observer reloads on the main queue; give it a runloop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertLessThan(pane.hexContentWidth, oneByteWidth)
    }

    /// Shrinking the word size and then zoom-to-fit must recalculate the
    /// pane's scroll content size: the document view tracks `max(contentWidth,
    /// viewport width)` afresh instead of staying at the pre-shrink width, which
    /// would make the pane scroll horizontally into empty space (§6).
    ///
    /// Word size 1 gives every byte its own word (the most inter-word gaps), so
    /// it is the widest grouping; 8-byte words pack tightest.
    func testWordSizeShrinkThenFitShrinksScrollContent() throws {
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("word-fit-\(UUID().uuidString).bin")
        try Data([UInt8](repeating: 0xAB, count: 64)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = PaneViewModel()
        try vm.open(url: url)
        let pane = FilePaneView(viewModel: vm)
        let hexView = try XCTUnwrap(pane.scrollView.documentView as? HexView)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        pane.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            pane.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            pane.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
        ])

        // Size the window to the widest (1-byte) content and lay out. The
        // document fills the viewport.
        window.setContentSize(NSSize(width: pane.contentFitWidth, height: 500))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let wideViewport = pane.scrollView.contentSize.width
        XCTAssertGreaterThan(wideViewport, 0, "precondition: the pane must have a viewport")
        XCTAssertEqual(hexView.frame.width, max(hexView.hexContentWidth, wideViewport), accuracy: 1,
                       "the document must fill the widest viewport")

        // Shrink the word size while the window is still wide: the content
        // collapses but the document keeps filling the viewport.
        UserDefaults.standard.set(8, forKey: WordSize.userDefaultsKey)
        WordSize.set(.eight)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertLessThan(hexView.hexContentWidth, wideViewport,
                          "precondition: 8-byte words are narrower than 1-byte")
        XCTAssertEqual(hexView.frame.width, max(hexView.hexContentWidth, wideViewport), accuracy: 1,
                       "the document still fills the unchanged wide viewport")

        // Zoom-to-fit: the window shrinks to the now-narrow content.
        window.setContentSize(NSSize(width: pane.contentFitWidth, height: 500))
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        // The document must track the new viewport — no horizontal scroll into
        // empty space.
        let viewport = pane.scrollView.contentSize.width
        XCTAssertLessThan(viewport, wideViewport, "precondition: zoom-to-fit shrank the window")
        XCTAssertEqual(hexView.frame.width, max(hexView.hexContentWidth, viewport), accuracy: 1)
        XCTAssertLessThanOrEqual(hexView.frame.width, viewport + 1,
                                 "the document must never be wider than the viewport")
    }
}
