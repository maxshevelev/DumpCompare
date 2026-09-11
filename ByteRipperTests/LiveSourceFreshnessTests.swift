import XCTest
import FITTool
import UEFIImage
@testable import FITToolUI
@testable import UEFIToolUI

/// Answers requests from a script the test writes, and records what was asked.
private final class FreshnessStub: URLProtocol {
    struct Answer {
        var status = 200
        var body = Data()
        var etag: String?
        var error: Error?
    }

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Answer] = []
        private(set) var asked: [String?] = []

        func queue(_ answer: Answer) { lock.lock(); answers.append(answer); lock.unlock() }

        func next(_ request: URLRequest) -> Answer {
            lock.lock()
            defer { lock.unlock() }
            asked.append(request.value(forHTTPHeaderField: "If-None-Match"))
            return answers.isEmpty ? Answer() : answers.removeFirst()
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    }

    nonisolated(unsafe) static var script = Script()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = FreshnessStub.script.next(request)
        if let error = answer.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: answer.status,
            httpVersion: "HTTP/1.1",
            headerFields: answer.etag.map { ["ETag": $0] } ?? [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

private let day: TimeInterval = 24 * 60 * 60

/// The two live sources the tool-modules own: `guids.csv` and the microcode
/// tree listing. Both used to be fetched again for every file a tool was
/// opened on, which is what these tests are watching for.
final class LiveSourceFreshnessTests: XCTestCase {
    private var script: FreshnessStub.Script!
    private var ticker: Ticker!

    override func setUp() {
        super.setUp()
        script = FreshnessStub.Script()
        FreshnessStub.script = script
        ticker = Ticker()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FreshnessStub.self]
        return URLSession(configuration: config)
    }

    private func ok(_ body: String, etag: String?) -> FreshnessStub.Answer {
        FreshnessStub.Answer(status: 200, body: Data(body.utf8), etag: etag)
    }

    private var notModified: FreshnessStub.Answer {
        FreshnessStub.Answer(status: 304)
    }

    private var offline: FreshnessStub.Answer {
        FreshnessStub.Answer(error: URLError(.notConnectedToInternet))
    }

    // MARK: guids.csv

    private let csv = "A0B1C2D3-E4F5-6789-ABCD-EF0123456789,MyDxeDriver\n"

    func testTheSecondTreeOfARunDoesNotFetchTheGuidsAgain() async throws {
        script.queue(ok(csv, etag: "guids-1"))
        let ticker = self.ticker!
        let repository = LongSoftGuidsRepository(session: makeSession(), ttl: day,
                                                 now: { ticker.now })

        let first = try await repository.guids()
        ticker.advance(60 * 60)
        let second = try await repository.guids()

        XCTAssertEqual(first.names.count, 1)
        XCTAssertEqual(second.names, first.names)
        XCTAssertEqual(script.count, 1, "680 KB, once per run")
    }

    func testAfterADayTheGuidsAreCheckedAndANotModifiedKeepsThem() async throws {
        script.queue(ok(csv, etag: "guids-1"))
        script.queue(notModified)
        let ticker = self.ticker!
        let repository = LongSoftGuidsRepository(session: makeSession(), ttl: day,
                                                 now: { ticker.now })

        let first = try await repository.guids()
        ticker.advance(day + 1)
        let second = try await repository.guids()

        XCTAssertEqual(second.names, first.names)
        XCTAssertEqual(script.asked, [nil, "guids-1"])
    }

    func testGuidsSurviveACheckThatCouldNotBeMade() async throws {
        script.queue(ok(csv, etag: "guids-1"))
        script.queue(offline)
        let ticker = self.ticker!
        let repository = LongSoftGuidsRepository(session: makeSession(), ttl: day,
                                                 now: { ticker.now })

        let first = try await repository.guids()
        ticker.advance(day + 1)
        let second = try await repository.guids()

        XCTAssertEqual(second.names, first.names, "the names do not disappear with the network")
    }

    // MARK: the microcode tree

    private let tree = """
    {"tree":[{"path":"Intel/cpu806EA_plat02_ver000000F0_2019-07-15_PRD_11223344.bin",\
    "type":"blob","size":100}]}
    """

    func testTheSecondFITTableOfARunDoesNotFetchTheTreeAgain() async throws {
        script.queue(ok(tree, etag: "tree-1"))
        let ticker = self.ticker!
        let repository = CPUMicrocodesRepository(session: makeSession(), ttl: day,
                                                 now: { ticker.now })

        let first = try await repository.catalogue()
        ticker.advance(60 * 60)
        let second = try await repository.catalogue()

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second, first)
        XCTAssertEqual(script.count, 1)
    }

    func testAfterADayTheTreeIsCheckedAndANotModifiedKeepsTheListing() async throws {
        script.queue(ok(tree, etag: "tree-1"))
        script.queue(notModified)
        let ticker = self.ticker!
        let repository = CPUMicrocodesRepository(session: makeSession(), ttl: day,
                                                 now: { ticker.now })

        let first = try await repository.catalogue()
        ticker.advance(day + 1)
        let second = try await repository.catalogue()

        XCTAssertEqual(second, first)
        XCTAssertEqual(script.asked, [nil, "tree-1"])
    }

    func testWithNothingHeldTheTreeStillFallsBackToTheFileOnDisk() async throws {
        // One successful fetch writes the disk copy, the way an ordinary run
        // would. The fallback is what answers the first open of the *next* run
        // on a bench whose network is gone — where there is nothing in memory.
        script.queue(ok(tree, etag: "tree-1"))
        let ticker = self.ticker!
        let warm = CPUMicrocodesRepository(session: makeSession(), ttl: day, now: { ticker.now })
        let expected = try await warm.catalogue()

        script.queue(offline)
        let cold = CPUMicrocodesRepository(session: makeSession(), ttl: day, now: { ticker.now })
        let entries = try await cold.catalogue()

        XCTAssertEqual(entries, expected, "a list from last week beats an error message")
    }
}
