import Foundation
import MEFirmware

/// Developer harness for the MEFirmware module (not part of the library).
///
/// Reads one file and runs the module's async `analyze(region:baseOffset:)`,
/// then prints the regions the parser found and the full `FirmwareAnalysis`
/// result model as JSON — the same Codable "structured output for UI" the app
/// renders, so a parse can be eyeballed without a window.
///
/// Best input is an engine region whose bytes start at `$FPT` (e.g. the ME
/// partition a tool like ByteRipper extracted); partition offsets are then
/// relative to that region. Pass the region's offset inside a larger dump as
/// the second argument and reported offsets are shifted by it.
///
/// Usage:
///   swift run MEFirmwareCLI <image> [baseOffset]
///
/// Examples:
///   swift run MEFirmwareCLI ~/dumps/me_region.bin
///   swift run MEFirmwareCLI ~/dumps/full.bin 0x1000     # region sits at 0x1000
@main
struct MEFirmwareCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage() }

        if args[1] == "--bench" {
            guard args.count >= 3 else { usage() }
            await bench(dumps: args[2], dat: args.count >= 4 ? args[3] : nil)
            return
        }

        let path = args[1]
        var baseOffset = 0
        if args.count >= 3 {
            switch parseOffset(args[2]) {
            case .success(let value): baseOffset = value
            case .failure(let reason): fail("bad baseOffset '\(args[2])': \(reason)")
            }
        }

        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            fail("cannot read \(path)")
        }

        let result: FirmwareAnalysis
        do {
            result = try await MEFirmwareAnalyzer().analyze(region: data, baseOffset: baseOffset)
        } catch {
            fail("analysis failed: \(error.localizedDescription)")
        }

        printSummary(result, path: path, size: data.count)
        if !result.issues.isEmpty {
            for issue in result.issues {
                print("issue[\(issue.severity.rawValue)]: \(issue.message)")
            }
        }
        print("--- FirmwareAnalysis JSON ---")
        print(json(result))
    }

    // MARK: - Bench

    /// A data source reading the three databases off disk, so a timing run
    /// measures parsing and not the network. Anything missing is left at the
    /// protocol default, which throws — the legs needing it are then skipped,
    /// so point `--dat` at a MEAnalyzer clone for a representative number.
    private struct LocalData: MEADataSource {
        var db = MEADatabase()
        var huffman: HuffmanDictionaries?

        func database() async throws -> MEADatabase { db }
        func huffmanDictionaries() async throws -> HuffmanDictionaries {
            guard let huffman else {
                throw MEADataError.malformed(file: "Huffman.dat (not supplied)")
            }
            return huffman
        }
    }

    /// Time `analyze` over every file in `dumps`, five runs each after a warm-up.
    /// Reports the best run, which is the one least polluted by other load.
    static func bench(dumps: String, dat: String?) async {
        var source = LocalData()
        if let dat {
            if let text = try? String(contentsOfFile: dat + "/MEA.dat", encoding: .utf8) {
                source.db = MEADatabase.parse(text)
            } else {
                print("warning: no MEA.dat under \(dat) — identification will be empty")
            }
            if let text = try? String(contentsOfFile: dat + "/Huffman.dat", encoding: .utf8) {
                source.huffman = try? HuffmanDictionaries.parse(text)
            }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dumps)) ?? [])
            .sorted()
            .filter { !$0.hasPrefix(".") }
        guard !files.isEmpty else { fail("no files in \(dumps)") }

        let runs = 5
        for name in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dumps + "/" + name),
                                       options: .mappedIfSafe) else { continue }
            _ = try? await MEFirmwareAnalyzer(data: source).analyze(region: data)
            var best = Double.infinity
            var total = 0.0
            for _ in 0..<runs {
                let start = Date()
                _ = try? await MEFirmwareAnalyzer(data: source).analyze(region: data)
                let elapsed = Date().timeIntervalSince(start)
                best = min(best, elapsed)
                total += elapsed
            }
            let label = name.padding(toLength: 18, withPad: " ", startingAt: 0)
            print(label + String(format: "%7.1f MiB   best %7.1f ms   mean %7.1f ms",
                                 Double(data.count) / 1_048_576,
                                 best * 1000, total / Double(runs) * 1000))
        }
    }

    static func printSummary(_ result: FirmwareAnalysis, path: String, size: Int) {
        let base = result.regions.isEmpty ? 0 : result.regions[0].offset
        _ = base
        print("file:       \(path) (\(size) bytes)")
        print("family:     \(result.family.rawValue)  release: \(result.release.rawValue)  type: \(result.type.rawValue)")
        print("variant:    '\(result.variant)'  version: \(result.version.text)  sku: '\(result.sku)'")
        if result.regions.isEmpty {
            print("FPT regions: none found")
        } else {
            print("FPT regions (\(result.regions.count)):  [id] name  offset  size  flags")
            for region in result.regions {
                let label = region.name.isEmpty ? "<erased>" : region.name
                print(String(format: "  [%2d] %@ 0x%08X 0x%08X 0x%08X",
                             region.id, label as NSString, region.offset, region.size, region.flags))
            }
        }
    }

    static func json(_ result: FirmwareAnalysis) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) else {
            return "<encoding failed>"
        }
        return text
    }

    private enum OffsetError: Error, CustomStringConvertible {
        case notHex, notDecimal
        var description: String {
            switch self {
            case .notHex: return "not a hex number"
            case .notDecimal: return "not a decimal number"
            }
        }
    }

    static func parseOffset(_ raw: String) -> Result<Int, Error> {
        if raw.lowercased().hasPrefix("0x") {
            guard let v = Int(raw.dropFirst(2), radix: 16) else { return .failure(OffsetError.notHex) }
            return .success(v)
        }
        guard let v = Int(raw) else { return .failure(OffsetError.notDecimal) }
        return .success(v)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        Usage: MEFirmwareCLI <image> [baseOffset]
               MEFirmwareCLI --bench <dumps-dir> [dat-dir]
          <image>      engine region whose bytes start at $FPT (e.g. ME partition)
          [baseOffset] offset of <image> inside a larger dump, decimal or 0x-hex (default 0)
          --bench      time analyze() over every file in <dumps-dir>, no network;
                       [dat-dir] holds MEA.dat/Huffman.dat (a MEAnalyzer clone)

        Examples:
          swift run MEFirmwareCLI ~/dumps/me_region.bin
          swift run MEFirmwareCLI ~/dumps/full.bin 0x1000
          swift run -c release MEFirmwareCLI --bench ~/Desktop/ME ~/Projects/MEAnalyzer
        """.utf8))
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
