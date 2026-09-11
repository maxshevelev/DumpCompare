import Foundation
import FreshData

/// The default `MEADataSource`: pulls the three upstream files live from
/// `raw.githubusercontent.com/platomav/MEAnalyzer/master/`.
///
/// Guarantees, mirroring `LongSoftGuidsRepository` in
/// `Modules/UEFITool/Sources/UEFIToolUI/GuidsSource.swift`:
/// - **Lazy** — nothing is fetched at init or app launch.
/// - **Single-flight** — concurrent first calls share one fetch, so a whole
///   run costs one network round per file, not one per caller.
/// - **In-memory only** — no disk cache. What is held lives as long as the
///   process, and a relaunch fetches again.
/// - **Checked once a day** — after that, the next call that needs the database
///   presents the stored `ETag`; GitHub answers `304` and the parsed database
///   is kept, so an unchanged week costs one round trip and no bytes. A check
///   that cannot be made leaves the held database in place, because a database
///   from yesterday is what a bench without a network is for.
///
/// The rules, and the failure states that go with them, are `Freshened`.
public actor MEAGitHubDataRepository: MEADataSource {
    private static let baseURL = URL(string: "https://raw.githubusercontent.com/platomav/MEAnalyzer/master/")!
    private static let userAgent = "ByteRipper"

    private let session: URLSession
    private let databaseData: Freshened<MEADatabase>
    private let huffmanData: Freshened<HuffmanDictionaries>

    public init() {
        self.init(session: MEAGitHubDataRepository.makeSession())
    }

    /// - Parameters:
    ///   - ttl: how long a fetched database is used before it is re-checked.
    ///   - now: the clock, so a test does not have to wait a day.
    init(
        session: URLSession,
        ttl: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.databaseData = Freshened(ttl: ttl, now: now)
        self.huffmanData = Freshened(ttl: ttl, now: now)
    }

    public func database() async throws -> MEADatabase {
        let session = session
        return try await databaseData.value { validator in
            try await Self.check(path: "MEA.dat", validator: validator, session: session) { text in
                // An unparseable revision is not fatal for the spine (no
                // identification yet) — but a body that is not MEA.dat at all
                // is worth surfacing.
                guard !text.isEmpty else { throw MEADataError.malformed(file: "MEA.dat") }
                return MEADatabase.parse(text)
            }
        }
    }

    public func huffmanDictionaries() async throws -> HuffmanDictionaries {
        let session = session
        return try await huffmanData.value { validator in
            try await Self.check(path: "Huffman.dat", validator: validator, session: session) { text in
                try HuffmanDictionaries.parse(text)
            }
        }
    }

    /// Emits when a check behind someone's back found a newer `MEA.dat`.
    public func databaseChanges() async -> AsyncStream<Void> {
        let replacements = await databaseData.changes()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        // The database itself is not carried across: whoever is listening asks
        // this repository for it again, and gets the one now held.
        let pump = Task {
            for await _ in replacements { continuation.yield(()) }
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    /// Make the next call re-check both files, whatever the clock says.
    public func markStale() async {
        await databaseData.markStale()
        await huffmanData.markStale()
    }

    /// Wait for a check running behind an answer — for tests, which must not
    /// race one.
    func settle() async {
        await databaseData.settle()
        await huffmanData.settle()
    }

    /// When each file last changed and when it was last confirmed current, for
    /// a panel that says how old its data is.
    public var freshness: (database: Freshened<MEADatabase>.Status?,
                           huffman: Freshened<HuffmanDictionaries>.Status?) {
        get async { (await databaseData.status, await huffmanData.status) }
    }

    // FileTable.dat parser is not ported yet; the protocol default throws
    // `.malformed` until the DB layer lands (see MEADataSource.swift).

    /// One conditional request, turned into the answer `Freshened` expects.
    private static func check<T: Sendable>(
        path: String,
        validator: String?,
        session: URLSession,
        parse: @Sendable (String) throws -> T
    ) async throws -> Freshened<T>.Outcome {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        // The session already ignores the local cache, but the request is
        // explicit about it: a `URLCache` hit here would answer `200` from
        // disk and the `304` would never reach us.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw map(urlError)
        } catch {
            throw MEADataError.offline(underlying: error.localizedDescription)
        }

        let http = response as? HTTPURLResponse
        if let http {
            if http.statusCode == 304 { return .unchanged }
            if http.statusCode == 429 { throw MEADataError.rateLimited }
            guard http.statusCode == 200 else {
                throw MEADataError.badResponse(status: http.statusCode)
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MEADataError.malformed(file: path)
        }
        let etag = http?.value(forHTTPHeaderField: "ETag")
        return .fresh(try parse(text), validator: etag)
    }

    private static func map(_ error: URLError) -> MEADataError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .offline(underlying: error.localizedDescription)
        default:
            return .offline(underlying: error.localizedDescription)
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.urlCache = nil                      // no disk cache by design
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}
