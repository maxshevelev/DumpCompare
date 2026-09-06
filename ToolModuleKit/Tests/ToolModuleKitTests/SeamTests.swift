import XCTest
import AppKit
@testable import ToolModuleKit

/// That the seam can actually be built on: a tool-module, a session and a host
/// written against these protocols and put together.
///
/// The app has the real host; what is proved here is that the protocols are
/// conformable and that the pieces fit — a requirement that cannot be met, or
/// one the host cannot satisfy, shows up as a compile error in this file rather
/// than in the first tool-module somebody writes.
final class SeamTests: XCTestCase {

    // MARK: - The stand-ins

    /// A host over an array of bytes.
    @MainActor private final class StubHost: ToolHost {
        var bytes: [UInt8]
        var published: ZoneMap = .empty
        var revealed: (range: Range<UInt64>, select: Bool)?

        init(bytes: [UInt8]) { self.bytes = bytes }

        var fileName = "bios.rom"
        var contentSize: UInt64 { UInt64(bytes.count) }
        var isReadOnly = false
        var caret: UInt64 = 0
        var selection: Range<UInt64>?

        func read(_ range: Range<UInt64>) throws -> [UInt8] {
            Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
        }

        func snapshot() throws -> any ToolContentReader { FrozenBytes(bytes: bytes) }

        /// What a real host does in the same order: refuse a read-only file,
        /// check the transaction, then write it as one step.
        func apply(_ transaction: ToolTransaction) throws {
            guard !isReadOnly else { throw StubError.readOnly }
            for write in try transaction.validated().writes {
                bytes.replaceSubrange(Int(write.offset)..<Int(write.range.upperBound),
                                      with: write.bytes)
            }
        }

        func publish(_ zones: ZoneMap) { published = zones.normalized(contentSize: contentSize) }
        func reveal(_ range: Range<UInt64>, select: Bool) { revealed = (range, select) }
        func requestFile(kinds: [String]) async -> ToolFile? { nil }
        func exportFile(_ bytes: [UInt8], suggestedName: String) async -> Bool { false }
        func beginProgress(_ title: String, onCancel: (() -> Void)?) -> any ToolProgress {
            StubProgress()
        }
    }

    private struct FrozenBytes: ToolContentReader {
        let bytes: [UInt8]
        var size: UInt64 { UInt64(bytes.count) }
        func read(at offset: UInt64, length: Int) throws -> [UInt8] {
            guard offset &+ UInt64(length) <= size else { throw StubError.pastTheEnd }
            return Array(bytes[Int(offset)..<(Int(offset) + length)])
        }
    }

    private enum StubError: Error { case readOnly, pastTheEnd }

    @MainActor private final class StubProgress: ToolProgress {
        func report(_ fraction: Double?) {}
        func finish() {}
    }

    /// Marks the first sixteen bytes as a zone and can write a byte.
    @MainActor private final class StubSession: ToolSession {
        let host: any ToolHost
        let viewController = NSViewController()
        private(set) var changes: [ToolContentChange] = []
        private(set) var stopped = false

        init(host: any ToolHost) { self.host = host }

        func start() {
            host.publish(ZoneMap(zones: [Zone(id: "head", name: "Header", range: 0..<16)],
                                 focus: "head"))
        }

        func contentChanged(_ change: ToolContentChange) { changes.append(change) }
        func stop() { stopped = true }
    }

    private struct StubModule: ToolModule {
        static let identifier = "dev.maxik.tool.stub"
        static let title = "Stub"
        static let preferredPanelWidth: CGFloat = 320
        @MainActor static func makeSession(host: any ToolHost) -> any ToolSession {
            StubSession(host: host)
        }
    }

    // MARK: - The seam

    @MainActor func testAModuleIsDescribedBeforeAnythingIsOpened() {
        let module: any ToolModule.Type = StubModule.self

        XCTAssertEqual(module.title, "Stub")
        XCTAssertEqual(module.identifier, "dev.maxik.tool.stub")
        XCTAssertEqual(module.preferredPanelWidth, 320)
    }

    @MainActor func testStartingASessionPublishesItsMapThroughTheHost() {
        let host = StubHost(bytes: [UInt8](repeating: 0xFF, count: 0x100))
        let session = StubModule.makeSession(host: host)

        session.start()

        XCTAssertEqual(host.published.zones.map(\.name), ["Header"])
        XCTAssertEqual(host.published.focus, "head")
        XCTAssertNotNil(session.viewController)
    }

    @MainActor func testATransactionFromASessionReachesTheBytes() throws {
        let host = StubHost(bytes: [UInt8](repeating: 0xFF, count: 0x100))

        try host.apply(ToolTransaction(name: "Set Type", offset: 0x0E, bytes: [0x01]))

        XCTAssertEqual(host.bytes[0x0E], 0x01)
        XCTAssertEqual(host.bytes[0x0D], 0xFF)
    }

    @MainActor func testAReadOnlyFileRefusesTheWholeTransaction() {
        let host = StubHost(bytes: [UInt8](repeating: 0xFF, count: 0x100))
        host.isReadOnly = true

        XCTAssertThrowsError(try host.apply(ToolTransaction(name: "Set Type",
                                                            offset: 0, bytes: [0x01])))
        XCTAssertEqual(host.bytes[0], 0xFF)
    }

    /// The point of taking a snapshot: a parse running over it is reading the
    /// file as it was when it started, whatever the document does meanwhile.
    @MainActor func testASnapshotDoesNotMoveWhenTheContentDoes() throws {
        let host = StubHost(bytes: [UInt8](repeating: 0xFF, count: 0x100))
        let frozen = try host.snapshot()

        try host.apply(ToolTransaction(name: "Set Type", offset: 0, bytes: [0x01]))

        XCTAssertEqual(try frozen.read(0..<1), [0xFF])
        XCTAssertEqual(host.bytes[0], 0x01)
    }

    /// A tool-module whose panel is a function of the file keeps nothing, and
    /// gets that without writing a line — which is what keeps the two members
    /// off the list of things every tool-module has to think about.
    @MainActor func testASessionKeepsNothingUnlessItSaysSo() {
        let session = StubModule.makeSession(host: StubHost(bytes: [1, 2, 3, 4]))

        XCTAssertNil(session.parkedState)
        session.restore(StubState(note: "ignored"))

        XCTAssertNil(session.parkedState, "and a restore it did not ask for changes nothing")
    }

    private struct StubState: ToolSessionState { var note: String }

    /// The half-open convenience on top of the reader's offset-and-length form.
    @MainActor func testTheReaderRefusesAReadPastTheEnd() throws {
        let frozen = try StubHost(bytes: [1, 2, 3, 4]).snapshot()

        XCTAssertEqual(try frozen.read(1..<3), [2, 3])
        XCTAssertThrowsError(try frozen.read(2..<6))
    }
}
