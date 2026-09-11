import XCTest
@testable import MEFirmware

/// Answers requests from a script the test writes, and records what was asked.
/// A `URLProtocol` rather than a stubbed `MEADataSource`, because what is under
/// test here *is* the HTTP: the conditional request, the `304`, and what is
/// held when the answer never comes.
final class StubProtocol: URLProtocol {
    struct Answer {
        var status: Int
        var body: String
        var etag: String?
        /// When set, the request fails instead of answering — no network.
        var error: Error?

        static func ok(_ body: String, etag: String? = nil) -> Answer {
            Answer(status: 200, body: body, etag: etag)
        }
        static let notModified = Answer(status: 304, body: "", etag: nil)
        static func failing() -> Answer {
            Answer(status: 0, body: "", etag: nil, error: URLError(.notConnectedToInternet))
        }
    }

    /// The script, and the log, shared by every instance the loader makes.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Answer] = []
        private(set) var asked: [(path: String, ifNoneMatch: String?)] = []

        func queue(_ answer: Answer) {
            lock.lock(); answers.append(answer); lock.unlock()
        }

        func next(for request: URLRequest) -> Answer {
            lock.lock()
            defer { lock.unlock() }
            asked.append((request.url?.lastPathComponent ?? "",
                          request.value(forHTTPHeaderField: "If-None-Match")))
            return answers.isEmpty ? .ok("") : answers.removeFirst()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }; return asked.count
        }
    }

    nonisolated(unsafe) static var script = Script()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let answer = StubProtocol.script.next(for: request)
        if let error = answer.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var headers: [String: String] = [:]
        if let etag = answer.etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: answer.status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A clock the test moves by hand.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}

/// `MEAGitHubDataRepository` — one fetch per run, a check once a day, and what
/// happens on a bench whose network is gone.
final class MEAGitHubDataRepositoryTests: XCTestCase {
    private var script: StubProtocol.Script!
    private var ticker: Ticker!

    override func setUp() {
        super.setUp()
        script = StubProtocol.Script()
        StubProtocol.script = script
        ticker = Ticker()
    }

    private func makeRepository() -> MEAGitHubDataRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let ticker = self.ticker!
        return MEAGitHubDataRepository(session: URLSession(configuration: config),
                                       now: { ticker.now })
    }

    /// A line MEA.dat's parser accepts, so the result is a real database.
    private let body = "Revision r300\n"

    func testTheSecondFileInARunCostsNoRequest() async throws {
        script.queue(.ok(body, etag: "etag-1"))
        let repository = makeRepository()

        _ = try await repository.database()
        ticker.advance(60 * 60)
        _ = try await repository.database()

        XCTAssertEqual(script.count, 1, "the second file is answered from memory")
    }

    func testAfterADayItAsksWithTheStoredETag() async throws {
        script.queue(.ok(body, etag: "etag-1"))
        script.queue(.notModified)
        let repository = makeRepository()

        _ = try await repository.database()
        ticker.advance(24 * 60 * 60 + 1)
        _ = try await repository.database()

        XCTAssertEqual(script.count, 2)
        XCTAssertNil(script.asked[0].ifNoneMatch, "nothing held, nothing to present")
        XCTAssertEqual(script.asked[1].ifNoneMatch, "etag-1")
    }

    func testANotModifiedKeepsTheDatabaseAndRestartsTheDay() async throws {
        script.queue(.ok(body, etag: "etag-1"))
        script.queue(.notModified)
        let repository = makeRepository()

        let first = try await repository.database()
        ticker.advance(24 * 60 * 60 + 1)
        let second = try await repository.database()
        XCTAssertEqual(first.revision, second.revision)

        ticker.advance(23 * 60 * 60)
        _ = try await repository.database()
        XCTAssertEqual(script.count, 2, "the day runs from the check, not from the fetch")
    }

    func testACheckThatCannotBeMadeKeepsYesterdaysDatabase() async throws {
        script.queue(.ok(body, etag: "etag-1"))
        script.queue(.failing())
        let repository = makeRepository()

        let first = try await repository.database()
        ticker.advance(24 * 60 * 60 + 1)
        let second = try await repository.database()

        XCTAssertEqual(first.revision, second.revision,
                       "no network is not a reason to lose what the tool already has")
    }

    func testAFailedFirstFetchDoesNotOutliveTheNetworkThatCausedIt() async throws {
        script.queue(.failing())
        script.queue(.ok(body, etag: "etag-1"))
        let repository = makeRepository()

        do {
            _ = try await repository.database()
            XCTFail("nothing is held, so the error belongs to the caller")
        } catch {}

        // Cable back in, tool opened again — in the same run.
        let database = try await repository.database()
        XCTAssertEqual(database.revision, 300)
    }

    func testMEADatAndHuffmanDatAreCheckedSeparately() async throws {
        script.queue(.ok(body, etag: "etag-mea"))
        script.queue(.ok("", etag: "etag-huff"))
        let repository = makeRepository()

        _ = try await repository.database()
        _ = try? await repository.huffmanDictionaries()

        XCTAssertEqual(script.asked.map { $0.path }, ["MEA.dat", "Huffman.dat"])
    }
}
