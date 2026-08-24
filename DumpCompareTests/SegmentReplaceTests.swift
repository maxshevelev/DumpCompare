import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.6 replacing a piece from a file, exercised through the real
/// `MainViewController`: the open panel (one file), the swap, and the refusal.
/// The panel is driven through the controller's seam and the swap runs inline,
/// so the tests assert on the pane's bytes after a swap, that one undo restores
/// them, the refusal's two sizes, and that a swap moves no cut.
@MainActor
final class SegmentReplaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(1, forKey: WordSize.userDefaultsKey)
    }

    /// What a replace flow leaves behind: the open panel it configured.
    private final class ReplaceCapture {
        var openPanel: NSOpenPanel?
    }

    /// A full controller whose active pane is open over `bytes`.
    private func makeController(_ bytes: [UInt8]) throws -> (MainViewController, NSWindow, URL) {
        let url = try tempFile(bytes)
        let controller = MainViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        try controller.windowModel.pane1.open(url: url)
        controller.apply(mode: .singleFile)
        window.layoutIfNeeded()
        return (controller, window, url)
    }

    private func cleanup(_ controller: MainViewController, _ url: URL) {
        controller.windowModel.pane1.close()
        try? FileManager.default.removeItem(at: url)
    }

    /// A temp donor file holding `bytes`, removed when the test ends.
    private func makeDonorFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentReplaceTests-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The pane's bytes for `range`, read live (edits included).
    private func paneBytes(_ pane: PaneViewModel, _ range: Range<UInt64>) throws -> [UInt8] {
        try XCTUnwrap(pane.byteStorage).read(at: range.lowerBound, length: Int(range.count))
    }

    /// Captures the segments form the controller would present modally and
    /// returns it — the test drives its `replacePiece` closure directly.
    private func capturedForm(_ controller: MainViewController) throws -> SegmentsFormController {
        var captured: SegmentsFormController?
        controller.segmentsFormPresenter = { captured = $0 }
        controller.showSegments()
        controller.segmentsFormPresenter = nil
        return try XCTUnwrap(captured, "showSegments must present the form")
    }

    /// Wires the controller's open-panel seam to return `donor` (capturing the
    /// panel it configured).
    private func wire(_ controller: MainViewController, _ capture: ReplaceCapture, donor: URL) {
        controller.segmentOpenPanel = { panel in
            capture.openPanel = panel
            return donor
        }
    }

    // MARK: - The bytes after a swap

    /// Replace Segment from File… reads the piece's range from the chosen file —
    /// the ordinary open panel, one file. The piece's bytes become the donor's;
    /// the rest of the file is untouched.
    func testTheBytesAfterASwap() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)  // S0 [0,8), S1 [8,16)

        let donor = try makeDonorFile([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        let form = try capturedForm(controller)
        let capture = ReplaceCapture()
        wire(controller, capture, donor: donor)

        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })
        let started = form.replacePiece?(piece) ?? false

        XCTAssertTrue(started, "the swap started")
        // The open panel chose files, not directories.
        let panel = try XCTUnwrap(capture.openPanel)
        XCTAssertTrue(panel.canChooseFiles, "the panel chooses a file")
        XCTAssertFalse(panel.canChooseDirectories, "the panel does not choose a directory")
        // S1's range now holds the donor's bytes; S0 is untouched.
        XCTAssertEqual(try paneBytes(pane, 8..<16),
                       [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7],
                       "S1 holds the donor's bytes")
        XCTAssertEqual(try paneBytes(pane, 0..<8), [UInt8](0..<8), "S0 is untouched")
        _ = window
    }

    // MARK: - One undo restores the swap

    /// The whole swap is one transaction, so one undo takes it all back — the
    /// piece's original bytes return.
    func testOneUndoRestoresTheSwap() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)

        let donor = try makeDonorFile([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        let form = try capturedForm(controller)
        let capture = ReplaceCapture()
        wire(controller, capture, donor: donor)

        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })
        _ = form.replacePiece?(piece) ?? false
        XCTAssertEqual(try paneBytes(pane, 8..<16),
                       [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7],
                       "the swap landed")

        let undid = try pane.undo()

        XCTAssertTrue(undid, "there was something to undo")
        XCTAssertEqual(try paneBytes(pane, 8..<16), [UInt8](8..<16),
                       "one undo restores the piece's original bytes")
        _ = window
    }

    // MARK: - The refusal's two sizes

    /// A donor whose length differs from the piece's is refused with both sizes
    /// named — the piece's length and the donor's — and nothing is written.
    func testTheRefusalNamesBothSizes() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)
        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })

        let donor = try makeDonorFile([0xB0, 0xB1, 0xB2])  // 3 bytes, not 8
        XCTAssertThrowsError(try pane.replaceSegment(piece, withContentsOf: donor)) { error in
            XCTAssertEqual(error as? SegmentReplaceError,
                           .lengthMismatch(pieceLength: 8, donorLength: 3),
                           "the refusal names both sizes")
        }
        XCTAssertEqual(try paneBytes(pane, 8..<16), [UInt8](8..<16),
                       "a refused swap writes nothing")
        _ = window
    }

    /// A refused swap does not start: the form's action reports no swap, and the
    /// piece's bytes are untouched.
    func testARefusedSwapDoesNotStart() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)

        let donor = try makeDonorFile([0xB0, 0xB1, 0xB2])  // wrong size
        let form = try capturedForm(controller)
        let capture = ReplaceCapture()
        wire(controller, capture, donor: donor)

        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })
        let started = form.replacePiece?(piece) ?? false

        XCTAssertFalse(started, "a refused swap does not start")
        XCTAssertEqual(try paneBytes(pane, 8..<16), [UInt8](8..<16),
                       "the piece's bytes are untouched")
        _ = window
    }

    // MARK: - No cut moves

    /// A same-length swap changes no size, so the partition's boundaries do not
    /// shift: the cuts stay where they were.
    func testASwapDoesNotMoveAnyCut() throws {
        let (controller, window, url) = try makeController([UInt8](0..<16))
        defer { cleanup(controller, url) }
        let pane = controller.windowModel.pane1
        pane.segmentStore.addCut(at: 8)  // S0 [0,8), S1 [8,16)
        let before = pane.segmentStore.segments.map(\.range)

        let donor = try makeDonorFile([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7])
        let form = try capturedForm(controller)
        let capture = ReplaceCapture()
        wire(controller, capture, donor: donor)

        let piece = try XCTUnwrap(pane.segmentStore.segments.first { $0.index == 1 })
        _ = form.replacePiece?(piece) ?? false

        XCTAssertEqual(pane.segmentStore.segments.map(\.range), before,
                       "a same-length swap moves no cut")
        _ = window
    }
}
