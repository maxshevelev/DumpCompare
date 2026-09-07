import Foundation
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
/// One request for the whole catalogue. There is no disk cache: the build
/// already ships a baseline, which is the offline answer, so a failed download
/// degrades to the baseline rather than to a stale file on disk.
public struct LongSoftGuidsRepository: GuidsSource {
    static let guidsURL = URL(
        string: "https://raw.githubusercontent.com/LongSoft/UEFITool/new_engine/common/guids.csv"
    )!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func guids() async throws -> GuidsCatalogue {
        let data = try await get(LongSoftGuidsRepository.guidsURL)
        return GuidsCatalogue.parse(data)
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // GitHub asks for one, and an anonymous request without it is answered
        // less kindly.
        request.setValue("DumpCompare", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GuidsSourceError.offline(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 403, 429: throw GuidsSourceError.rateLimited
        default: throw GuidsSourceError.badResponse(status: http.statusCode)
        }
    }
}
