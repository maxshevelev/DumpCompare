import Foundation

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
            // A search matches the CPUID as it is written, the revision, or the
            // file name — whichever the user has in front of them.
            return entry.cpuidText.hasPrefix(needle)
                || entry.revisionText.hasPrefix(needle)
                || entry.fileName.uppercased().contains(needle)
        }
    }

    /// How many there are of each, for the popup — a vendor the collection has
    /// nothing for is worth showing as empty rather than hiding.
    public static func counts(
        in entries: [MicrocodeCatalogueEntry]
    ) -> [MicrocodeVendor: Int] {
        entries.reduce(into: [:]) { counts, entry in counts[entry.vendor, default: 0] += 1 }
    }
}
