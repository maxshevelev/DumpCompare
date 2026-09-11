import Foundation
import FreshData
import UEFIImage

/// Where the GUID catalogue comes from.
///
/// A protocol because the app's tests must not touch the network: a suite that
/// reaches GitHub is a suite that fails on a train. The real one is below; a
/// test installs its own.
public protocol GuidsSource: Sendable {
    /// The fresh catalogue, parsed from `common/guids.csv`.
    func guids() async throws -> GuidsCatalogue
}

/// What went wrong on the way to the catalogue, in words a bench can act on.
public enum GuidsSourceError: LocalizedError, Equatable {
    case offline(underlying: String)
    case badResponse(status: Int)
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .offline(let underlying):
            return "Could not reach github.com: \(underlying)"
        case .badResponse(let status):
            return "github.com answered \(status)."
        case .rateLimited:
            return "GitHub is rate-limiting this address. The names shown are the"
                + " ones shipped in the build, and they will refresh on the next open."
        }
    }
}

/// `github.com/LongSoft/UEFITool`, branch `new_engine`, `common/guids.csv`.
///
/// One request for the whole catalogue, and — because 680 KB of CSV is also a
/// parse — the parsed catalogue is held for the life of the process and
/// re-checked once a day (`Freshened`). Without that, every file a tree was
/// opened on paid for the same download again.
///
/// There is still no disk cache: the build already ships a baseline, which is
/// the offline answer for a fresh launch, so a first download that fails
/// degrades to the baseline rather than to a stale file on disk.
public struct LongSoftGuidsRepository: GuidsSource {
    static let guidsURL = URL(
        string: "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/common/guids.csv"
    )!

    private let session: URLSession
    private let held: Freshened<GuidsCatalogue>

    public init(session: URLSession = .shared) {
        self.init(session: session, ttl: 24 * 60 * 60)
    }

    /// - Parameters:
    ///   - ttl: how long a fetched catalogue is used before it is re-checked.
    ///   - now: the clock, so a test does not have to wait a day.
    init(
        session: URLSession,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.held = Freshened(ttl: ttl, now: now)
    }

    public func guids() async throws -> GuidsCatalogue {
        let session = session
        return try await held.value { validator in
            let answer = try await Self.get(Self.guidsURL, validator: validator, session: session)
            switch answer {
            case .unchanged:
                return .unchanged
            case .body(let data, let etag):
                return .fresh(GuidsCatalogue.parse(data), validator: etag)
            }
        }
    }

    /// Make the next `guids()` re-check, whatever the clock says.
    public func markStale() async {
        await held.markStale()
    }

    /// When the catalogue last changed and when it was last confirmed current.
    public var freshness: Freshened<GuidsCatalogue>.Status? {
        get async { await held.status }
    }

    private enum Answer {
        case unchanged
        case body(Data, etag: String?)
    }

    private static func get(
        _ url: URL,
        validator: String?,
        session: URLSession
    ) async throws -> Answer {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // `URLSession.shared` has a cache of its own, which would answer `200`
        // from disk and swallow the `304` this request is asking for.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-None-Match")
        }
        // GitHub asks for one, and an anonymous request without it is answered
        // less kindly.
        request.setValue("ByteRipper", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GuidsSourceError.offline(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return .body(data, etag: nil) }
        switch http.statusCode {
        case 304: return .unchanged
        case 200..<300: return .body(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 403, 429: throw GuidsSourceError.rateLimited
        default: throw GuidsSourceError.badResponse(status: http.statusCode)
        }
    }
}
