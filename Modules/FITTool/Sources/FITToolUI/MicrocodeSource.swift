import FITTool
import Foundation
import FreshData

/// Where the list of microcode, and the microcode itself, comes from.
///
/// A protocol because the app's tests must not touch the network: a suite that
/// reaches GitHub is a suite that fails on a train. The real one is below; a
/// test installs its own.
public protocol MicrocodeSource: Sendable {
    /// Every Intel microcode in the collection, read from the file names.
    func catalogue() async throws -> [MicrocodeCatalogueEntry]
    /// One file's bytes.
    func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8]

    /// Emits when a background check has replaced the listing with a newer
    /// one, so a table's "latest" verdicts can be settled again against what
    /// actually exists now. A source that never changes its mind never emits.
    func catalogueChanges() async -> AsyncStream<[MicrocodeCatalogueEntry]>
}

extension MicrocodeSource {
    /// A source with nothing to announce — a stub in a test, a local folder.
    public func catalogueChanges() async -> AsyncStream<[MicrocodeCatalogueEntry]> {
        AsyncStream { $0.finish() }
    }
}

/// What went wrong on the way to the catalogue, in words a bench can act on.
public enum MicrocodeSourceError: LocalizedError, Equatable {
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
            return "GitHub is rate-limiting this address. Try again in a few minutes,"
                + " or use Choose File… with a microcode you already have."
        }
    }
}

/// `github.com/platomav/CPUMicrocodes`, over HTTPS.
///
/// One request for the whole list — GitHub's recursive tree listing — and one
/// per file downloaded. The parsed list is held for the life of the process and
/// re-checked once a day (`Freshened`), so the second file a FIT table is
/// opened on does not fetch the tree again; on `api.github.com` a `304` is also
/// not counted against the rate limit.
///
/// The list is cached on disk as well, which answers the *first* open of a run
/// on a bench with no network — where there is nothing held to fall back to.
public struct CPUMicrocodesRepository: MicrocodeSource {
    /// The tree of the default branch, in one request.
    static let treeURL = URL(
        string: "https://api.github.com/repos/platomav/CPUMicrocodes/git/trees/master?recursive=1"
    )!
    static let downloadBase = URL(
        string: "https://raw.githubusercontent.com/platomav/CPUMicrocodes/master/"
    )!

    private let session: URLSession
    private let cache: URL?
    private let held: Freshened<[MicrocodeCatalogueEntry]>

    public init(session: URLSession = .shared) {
        self.init(session: session, ttl: 24 * 60 * 60)
    }

    /// - Parameters:
    ///   - ttl: how long a fetched listing is used before it is re-checked.
    ///   - now: the clock, so a test does not have to wait a day.
    init(
        session: URLSession,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CPUMicrocodes-tree.json")
        self.held = Freshened(ttl: ttl, now: now)
    }

    public func catalogue() async throws -> [MicrocodeCatalogueEntry] {
        let session = session
        let cache = cache
        do {
            return try await held.value { validator in
                let request = Self.request(Self.treeURL, validator: validator, ignoringCache: true)
                switch try await Self.send(request, session: session) {
                case .unchanged:
                    return .unchanged
                case .body(let data, let etag):
                    let entries = try MicrocodeCatalogue.entries(fromTree: data)
                    if let cache { try? data.write(to: cache) }
                    return .fresh(entries, validator: etag)
                }
            }
        } catch {
            // `Freshened` throws only when it holds nothing, so this is the
            // first listing of the run and the network was not there for it. A
            // list from last week is worth more than an error message: the file
            // names it holds do not change once written.
            guard let cache, let data = try? Data(contentsOf: cache),
                  let entries = try? MicrocodeCatalogue.entries(fromTree: data), !entries.isEmpty
            else { throw error }
            return entries
        }
    }

    public func catalogueChanges() async -> AsyncStream<[MicrocodeCatalogueEntry]> {
        await held.changes()
    }

    /// Wait for a check running behind an answer — for tests, which must not
    /// race one.
    func settle() async {
        await held.settle()
    }

    /// Make the next `catalogue()` re-check, whatever the clock says.
    public func markStale() async {
        await held.markStale()
    }

    /// When the listing last changed and when it was last confirmed current.
    public var freshness: Freshened<[MicrocodeCatalogueEntry]>.Status? {
        get async { await held.status }
    }

    public func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8] {
        let url = CPUMicrocodesRepository.downloadBase.appendingPathComponent(entry.path)
        // A microcode file never changes once written, so this one asks
        // unconditionally and lets any HTTP cache help if it can.
        let request = Self.request(url, validator: nil, ignoringCache: false)
        switch try await Self.send(request, session: session) {
        case .body(let data, _):
            return [UInt8](data)
        case .unchanged:
            // Nothing was presented to compare against, so this cannot happen.
            throw MicrocodeSourceError.badResponse(status: 304)
        }
    }

    private enum Answer {
        case unchanged
        case body(Data, etag: String?)
    }

    private static func request(
        _ url: URL,
        validator: String?,
        ignoringCache: Bool
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if ignoringCache {
            // `URLSession.shared` has a cache of its own, which would answer
            // `200` from disk and swallow the `304` this request asks for.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-None-Match")
        }
        // GitHub asks for one, and an anonymous request without it is answered
        // less kindly.
        request.setValue("ByteRipper", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> Answer {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MicrocodeSourceError.offline(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return .body(data, etag: nil) }
        switch http.statusCode {
        case 304: return .unchanged
        case 200..<300: return .body(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 403, 429: throw MicrocodeSourceError.rateLimited
        default: throw MicrocodeSourceError.badResponse(status: http.statusCode)
        }
    }
}
