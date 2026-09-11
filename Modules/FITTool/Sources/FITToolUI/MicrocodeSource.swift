import FITTool
import Foundation

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
/// per file downloaded. The list is cached on disk, so a bench that fetched it
/// once can go on working without a network, which is the ordinary condition of
/// a bench.
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

    public init(session: URLSession = .shared) {
        self.session = session
        self.cache = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CPUMicrocodes-tree.json")
    }

    public func catalogue() async throws -> [MicrocodeCatalogueEntry] {
        do {
            let data = try await get(CPUMicrocodesRepository.treeURL)
            let entries = try MicrocodeCatalogue.entries(fromTree: data)
            if let cache { try? data.write(to: cache) }
            return entries
        } catch {
            // A list from last week is worth more than an error message: the
            // file names it holds do not change once written.
            guard let cache, let data = try? Data(contentsOf: cache),
                  let entries = try? MicrocodeCatalogue.entries(fromTree: data), !entries.isEmpty
            else { throw error }
            return entries
        }
    }

    public func download(_ entry: MicrocodeCatalogueEntry) async throws -> [UInt8] {
        let url = CPUMicrocodesRepository.downloadBase.appendingPathComponent(entry.path)
        return [UInt8](try await get(url))
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // GitHub asks for one, and an anonymous request without it is answered
        // less kindly.
        request.setValue("ByteRipper", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MicrocodeSourceError.offline(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 403, 429: throw MicrocodeSourceError.rateLimited
        default: throw MicrocodeSourceError.badResponse(status: http.statusCode)
        }
    }
}
