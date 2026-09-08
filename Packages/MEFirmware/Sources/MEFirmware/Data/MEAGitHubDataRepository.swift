import Foundation

/// The default `MEADataSource`: pulls the three upstream files live from
/// `raw.githubusercontent.com/platomav/MEAnalyzer/master/`.
///
/// Guarantees, mirroring `LongSoftGuidsRepository` in
/// `Modules/UEFITool/Sources/UEFIToolUI/GuidsSource.swift`:
/// - **Lazy** — nothing is fetched at init or app launch.
/// - **Single-flight** — concurrent first calls share one in-flight `Task`, so
///   a whole run costs one network round per file, not one per caller.
/// - **In-memory only** — no disk cache; the next launch re-fetches, which is
///   exactly what "these databases change every week" wants.
public actor MEAGitHubDataRepository: MEADataSource {
    private static let baseURL = URL(string: "https://raw.githubusercontent.com/platomav/MEAnalyzer/master/")!
    private static let userAgent = "DumpCompare"

    private let session: URLSession
    private var databaseTask: Task<MEADatabase, Error>?

    public init() {
        self.init(session: MEAGitHubDataRepository.makeSession())
    }

    init(session: URLSession) {
        self.session = session
    }

    public func database() async throws -> MEADatabase {
        if let cached = databaseTask {
            return try await cached.value
        }
        let task = Task { try await self.fetchDatabase() }
        databaseTask = task
        return try await task.value
    }

    // Huffman/FileTable parsers are not ported yet; the protocol defaults throw
    // `.malformed` until the DB layer lands (see MEADataSource.swift).

    private func fetchDatabase() async throws -> MEADatabase {
        let text = try await fetchText(path: "MEA.dat")
        let parsed = MEADatabase.parse(text)
        // An unparseable revision is not fatal for the spine (no identification
        // yet) — but a body that is not MEA.dat at all is worth surfacing.
        guard !text.isEmpty else { throw MEADataError.malformed(file: "MEA.dat") }
        return parsed
    }

    private func fetchText(path: String) async throws -> String {
        let url = Self.baseURL.appendingPathComponent(path)
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 429 { throw MEADataError.rateLimited }
                throw MEADataError.badResponse(status: http.statusCode)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw MEADataError.malformed(file: path)
            }
            return text
        } catch let error as MEADataError {
            throw error
        } catch let urlError as URLError {
            throw map(urlError)
        } catch {
            throw MEADataError.offline(underlying: error.localizedDescription)
        }
    }

    private func map(_ error: URLError) -> MEADataError {
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
