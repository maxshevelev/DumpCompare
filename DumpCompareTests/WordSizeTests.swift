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
        let vm = PaneViewModel()
        try vm.open(url: url)
        let pane = FilePaneView(viewModel: vm)
        let oneByteWidth = pane.hexContentWidth

        WordSize.set(.eight)
        // The observer reloads on the main queue; give it a runloop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertLessThan(pane.hexContentWidth, oneByteWidth)
    }
}
