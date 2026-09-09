import Foundation
import UEFIImage

/// The four kinds of microcode the collection holds, one directory each.
///
/// Only Intel can go into a FIT (§6, §7.1) — the table names nothing else — so
/// only Intel is ever offered. The other three are read all the same, because
/// the listing is of the whole repository and telling them apart is what keeps
/// AMD's names from being read as Intel's.
public enum MicrocodeVendor: String, CaseIterable, Sendable {
    case intel = "Intel"
    case amd = "AMD"
    case via = "VIA"
    case freescale = "Freescale"

    /// The directory in the repository, which is also how an entry's vendor is
    /// recognised.
    public var directory: String { rawValue + "/" }
}

/// One microcode file in the catalogue.
///
/// Everything here is read out of the file's *name*: the collection at
/// `github.com/platomav/CPUMicrocodes` encodes what a person needs to choose by
/// into it, which is what makes thousands of files searchable without
/// downloading any of them.
///
/// ```
/// Intel:     cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.bin
/// AMD:       cpu00800F11_ver08001129_2017-07-14_4F426450.bin
/// VIA:       cpu10690_ver00000001_sig[BJ_10690.020]_2017-01-09_A8B24DC2.bin
/// Freescale: soc8360_rev2.1_sig[Soft-UART]_3725F40B.bin
/// ```
///
/// The four disagree about almost everything: only Intel has a platform id,
/// Freescale has no CPUID and no hexadecimal revision at all. So the fields
/// that not everyone has are optional, and the text ones are what the panel
/// shows.
public struct MicrocodeCatalogueEntry: Equatable, Sendable, Identifiable {
    public var vendor: MicrocodeVendor
    /// The path in the repository, which is also its identity.
    public var path: String
    /// The processor it is for, where that is a number. Nil for Freescale,
    /// whose files name a system-on-chip instead.
    public var cpuid: UInt32?
    /// What identifies the processor, as the file name writes it: `906EB` for
    /// Intel and AMD, `8360` for a Freescale SoC.
    public var cpuidText: String
    /// The platform ids this update is for, as a bit mask. Intel only.
    public var platformID: UInt32?
    /// The revision, as written: `7C`, or `2.1` for Freescale.
    public var revisionText: String
    /// `2017-12-03`, as written. Empty where the name carries no date.
    public var date: String
    /// `PRD` rather than `PRE`: released rather than pre-release.
    public var isProduction: Bool
    public var size: UInt64

    public var id: String { path }

    /// Two hex digits at least, the way the file name writes it: `plat02`, not
    /// `plat2`.
    public var platformText: String {
        guard let platformID else { return "" }
        let text = String(platformID, radix: 16, uppercase: true)
        return text.count < 2 ? "0" + text : text
    }

    public var fileName: String { String(path.split(separator: "/").last ?? "") }

    /// The revision as a number, where the file name writes one: `7C` reads as
    /// 0x7C. Nil for Freescale, whose `2.1` is no hexadecimal — one more way in
    /// which it is not like the other three.
    public var revision: UInt32? { UInt32(revisionText, radix: 16) }
}

/// How one installed microcode stands against the catalogue: is there a newer
/// revision out there for the same processor and platform?
///
/// A value rather than a question asked against a live fetch, so a row's
/// verdict is decided in the pure target and tested by `swift test`. The panel
/// turns it into an icon in the Type column — green where the row is newest,
/// orange where the catalogue has newer — and nothing where there is no basis
/// for a verdict.
public enum MicrocodeLatest: Equatable, Sendable {
    /// The newest revision the catalogue lists for this CPUID and platform.
    case latest
    /// The catalogue holds a newer one — which, so the pointer can name it.
    case outdated(newestRevision: UInt32)
    /// No basis for a verdict: no catalogue yet, nothing it holds for this
    /// CPUID and platform, or a revision newer than any it lists (the
    /// collection is behind the board).
    case notRated
}

/// The list of what can be added, read from the repository's file names.
///
/// Downloading is not this package's business — it has no network in it and no
/// URLSession — but *understanding* the list is, so the whole of it can be
/// tested by `swift test` over a fixture the size of a paragraph.
public enum MicrocodeCatalogue {
    /// Parses GitHub's recursive tree listing — one request for the whole
    /// repository, where the contents API would need a page per directory.
    public static func entries(fromTree data: Data) throws -> [MicrocodeCatalogueEntry] {
        struct Tree: Decodable {
            struct Node: Decodable {
                var path: String
                var type: String
                var size: UInt64?
            }
            var tree: [Node]
        }
        let tree = try JSONDecoder().decode(Tree.self, from: data)
        return tree.tree
            .filter { $0.type == "blob" }
            .compactMap { entry(at: $0.path, size: $0.size ?? 0) }
            .sorted {
                ($0.cpuidText.count, $0.cpuidText, $0.revisionText)
                    < ($1.cpuidText.count, $1.cpuidText, $1.revisionText)
            }
    }

    /// Reads one file name. Nil for anything that is not a microcode file —
    /// every directory holds a licence too.
    public static func entry(at path: String, size: UInt64) -> MicrocodeCatalogueEntry? {
        guard let vendor = MicrocodeVendor.allCases.first(where: { path.hasPrefix($0.directory) })
        else { return nil }
        let name = String(path.split(separator: "/").last ?? "")
        guard name.hasSuffix(".bin") else { return nil }
        let fields = name.dropLast(4).split(separator: "_").map(String.init)

        func field(after prefix: String) -> String? {
            fields.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        func hex(after prefix: String) -> UInt32? {
            field(after: prefix).flatMap { UInt32($0, radix: 16) }
        }
        // Freescale names a SoC where everyone else names a CPUID, and its
        // revision is `2.1` rather than a hexadecimal number. `soc8360` reads
        // as valid hexadecimal, which is exactly why the two are told apart by
        // the field they came from rather than by whether they parse.
        let processor = field(after: "cpu")
        guard let identifier = processor ?? field(after: "soc") else { return nil }
        guard let revision = field(after: "ver") ?? field(after: "rev") else { return nil }

        // The date is the field shaped like one; not every name has one.
        let date = fields.first {
            $0.count == 10 && $0.filter { $0 == "-" }.count == 2
                && $0.allSatisfy { $0.isNumber || $0 == "-" }
        }
        return MicrocodeCatalogueEntry(
            vendor: vendor,
            path: path,
            cpuid: processor.flatMap { UInt32($0, radix: 16) },
            // Leading zeros dropped, so a search for what is on screen matches:
            // AMD writes `00800F11` where Intel writes `906EB`.
            cpuidText: processor.flatMap { UInt32($0, radix: 16) }
                .map { String($0, radix: 16, uppercase: true) } ?? identifier,
            platformID: hex(after: "plat"),
            revisionText: UInt32(revision, radix: 16)
                .map { String($0, radix: 16, uppercase: true) } ?? revision,
            date: date ?? "",
            isProduction: !fields.contains("PRE"),
            size: size
        )
    }

    /// What the form shows: one vendor's microcode, narrowed by what the user
    /// typed. "Vendor" and not "platform" throughout, because Intel's names
    /// carry a `plat` field that means something else.
    ///
    /// `cpuidsInTheImage` is the narrowing a bench asks for by hand: a dump is
    /// for one board, and what is worth adding to it is usually a newer
    /// revision of a CPUID its table already names.
    public static func filter(
        _ entries: [MicrocodeCatalogueEntry],
        vendor: MicrocodeVendor? = nil,
        search: String = "",
        cpuidsInTheImage: Set<UInt32>? = nil
    ) -> [MicrocodeCatalogueEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).uppercased()
        return entries.filter { entry in
            if let vendor, entry.vendor != vendor { return false }
            if let cpuidsInTheImage {
                guard let cpuid = entry.cpuid, cpuidsInTheImage.contains(cpuid) else { return false }
            }
            guard !needle.isEmpty else { return true }
            // A search is by the CPUID — what a bench writes down and looks up
            // — and by nothing else: the revision and the file name are the
            // catalogue's, and matching them is a guess about which the user
            // meant.
            return entry.cpuidText.hasPrefix(needle)
        }
    }

    /// How many there are of each, for the popup — a vendor the collection has
    /// nothing for is worth showing as empty rather than hiding.
    public static func counts(
        in entries: [MicrocodeCatalogueEntry]
    ) -> [MicrocodeVendor: Int] {
        entries.reduce(into: [:]) { counts, entry in counts[entry.vendor, default: 0] += 1 }
    }

    /// Whether an installed microcode is the newest the catalogue lists for its
    /// processor and platform.
    ///
    /// The platform is part of the match, not a refinement of it: two updates
    /// of one CPUID can serve different platforms (§7.1's platform ids, and the
    /// `plat02`/`plat22` in the names), and a newer `plat22` revision does not
    /// outdate a `plat02` update. The platform id is compared exactly as the
    /// file name writes it, because that is the value an update's own header
    /// stores (§7.1): `plat22` names an update whose header reads 0x22.
    ///
    /// A revision newer than anything the catalogue lists is not "latest": the
    /// collection is behind the board, and a behind catalogue cannot confirm
    /// what it does not know.
    public static func latest(
        of header: MicrocodeHeader,
        in entries: [MicrocodeCatalogueEntry]
    ) -> MicrocodeLatest {
        let revisions = entries.compactMap { entry -> UInt32? in
            guard entry.cpuid == header.processorSignature,
                  entry.platformID == header.platformIDs
            else { return nil }
            return entry.revision
        }
        guard let newest = revisions.max() else { return .notRated }
        if header.updateRevision > newest { return .notRated }
        if header.updateRevision == newest { return .latest }
        return .outdated(newestRevision: newest)
    }
}
