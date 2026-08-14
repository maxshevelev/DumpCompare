import XCTest
@testable import DumpCompare

/// M6 tests for the external-change watcher (§5.5): it fires on an external
/// write, stops watching after `stop()`, and `rebind(to:)` moves it to a new
/// file (atomic saves can replace the inode).
final class FileChangeWatcherTests: XCTestCase {
    private func tempFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-\(name)-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func settle() async {
        // Let the dispatch source register before we trigger events.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func testFiresOnExternalWrite() async throws {
        let url = try tempFile("fire", [0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        let fired = expectation(description: "watcher fired")

        let watcher = FileChangeWatcher(url: url)
        watcher.onChange = { fired.fulfill() }
        await settle()

        try Data([0x01]).write(to: url)

        await fulfillment(of: [fired], timeout: 5)
        watcher.stop()
    }

    func testDoesNotFireAfterStop() async throws {
        let url = try tempFile("stop", [0x00])
        defer { try? FileManager.default.removeItem(at: url) }
        let unexpected = expectation(description: "should not fire")
        unexpected.isInverted = true

        let watcher = FileChangeWatcher(url: url)
        watcher.onChange = { unexpected.fulfill() }
        await settle()
        watcher.stop()

        try Data([0x01]).write(to: url)

        await fulfillment(of: [unexpected], timeout: 1.5)
    }

    func testRebindWatchesNewFile() async throws {
        let url1 = try tempFile("old", [0x00])
        let url2 = try tempFile("new", [0x00])
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }
        let fired = expectation(description: "rebound watcher fired")

        let watcher = FileChangeWatcher(url: url1)
        watcher.onChange = { fired.fulfill() }
        await settle()
        watcher.rebind(to: url2)
        await settle()

        try Data([0x01]).write(to: url2)

        await fulfillment(of: [fired], timeout: 5)
        watcher.stop()
    }
}
