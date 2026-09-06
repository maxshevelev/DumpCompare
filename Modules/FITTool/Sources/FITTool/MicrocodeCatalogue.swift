import Foundation

/// One microcode file in the catalogue.
///
/// Everything here is read out of the file's *name*: the collection at
/// `github.com/platomav/CPUMicrocodes` encodes the CPUID, the platform, the
/// revision and the date into it, which is what makes a list of a thousand
/// files searchable without downloading any of them.
///
/// ```
/// cpu906EB_plat02_ver0000007C_2017-12-03_PRD_5046D998.bin
///    │        │        │          │       │      └ checksum
///    │        │        │          │       └ production or pre-release
///    │        │        │          └ date
///    │        │        └ revision
///    │        └ platform id (Intel only)
///    └ CPUID
/// ```
public struct MicrocodeCatalogueEntry: Equatable, Sendable, Identifiable {
    /// The path in the repository, which is also its identity.
    public var path: String
    public var cpuid: UInt32
    /// The platform ids this update is for, as a bit mask. Intel only.
    public var platformID: UInt32?
    public var revision: UInt32
    /// `2017-12-03`, as written.
    public var date: String
    /// `PRD` rather than `PRE`: released rather than pre-release.
    public var isProduction: Bool
    public var size: UInt64

    public var id: String { path }

    /// The name as a bench writes it: five hex digits, no leading zero — the
    /// same form the FIT panel shows.
    public var cpuidText: String { String(cpuid, radix: 16, uppercase: true) }

    public var revisionText: String { String(revision, radix: 16, uppercase: true) }

    public var platformText: String {
        platformID.map { String($0, radix: 16, uppercase: true) } ?? ""
    }

    public var fileName: String { String(path.split(separator: "/").last ?? "") }
}

/// The list of what can be added, read from the repository's file names.
///
/// Downloading is not this package's business — it has no network in it and no
/// URLSession — but *understanding* the list is, so the whole of it can be
/// tested by `swift test` over a fixture the size of a paragraph.
public enum MicrocodeCatalogue {
    /// The one directory a FIT can take anything from. AMD and VIA microcode is
    /// in the same repository and cannot go in an Intel FIT (§6, §7.1), so
    /// offering it would be offering a mistake.
    public static let intelDirectory = "Intel/"

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
        return tree.tree.compactMap { node in
            guard node.type == "blob", node.path.hasPrefix(intelDirectory) else { return nil }
            return entry(at: node.path, size: node.size ?? 0)
        }
        .sorted { ($0.cpuid, $0.revision) < ($1.cpuid, $1.revision) }
    }

    /// Reads one file name. Nil for anything that is not a microcode file — the
    /// directory holds a licence too.
    public static func entry(at path: String, size: UInt64) -> MicrocodeCatalogueEntry? {
        let name = String(path.split(separator: "/").last ?? "")
        guard name.hasSuffix(".bin") else { return nil }
        let fields = name.dropLast(4).split(separator: "_").map(String.init)

        func hex(after prefix: String) -> UInt32? {
            guard let field = fields.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            return UInt32(field.dropFirst(prefix.count), radix: 16)
        }
        guard let cpuid = hex(after: "cpu"), let revision = hex(after: "ver") else { return nil }

        // The date is the field shaped like one; the release marker is a word.
        let date = fields.first {
            $0.count == 10 && $0.filter { $0 == "-" }.count == 2
                && $0.allSatisfy { $0.isNumber || $0 == "-" }
        }
        return MicrocodeCatalogueEntry(
            path: path,
            cpuid: cpuid,
            platformID: hex(after: "plat"),
            revision: revision,
            date: date ?? "",
            isProduction: !fields.contains("PRE"),
            size: size
        )
    }

    /// What the form shows: the catalogue narrowed by the three things a bench
    /// narrows it by.
    ///
    /// `cpuidsInTheImage` is the useful default — a dump is for one board, and
    /// the microcode worth adding to it is almost always a newer revision of a
    /// CPUID already in its table, or a sibling stepping of one.
    public static func filter(
        _ entries: [MicrocodeCatalogueEntry],
        search: String = "",
        platformID: UInt32? = nil,
        cpuidsInTheImage: Set<UInt32>? = nil
    ) -> [MicrocodeCatalogueEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).uppercased()
        return entries.filter { entry in
            if let platformID, entry.platformID != platformID { return false }
            if let cpuidsInTheImage, !cpuidsInTheImage.contains(entry.cpuid) { return false }
            guard !needle.isEmpty else { return true }
            // A search matches the CPUID as it is written, the revision, or the
            // file name — whichever the user has in front of them.
            return entry.cpuidText.hasPrefix(needle)
                || entry.revisionText.hasPrefix(needle)
                || entry.fileName.uppercased().contains(needle)
        }
    }

    /// The platform ids present, for the popup. Nil for microcode that has none.
    public static func platformIDs(in entries: [MicrocodeCatalogueEntry]) -> [UInt32] {
        Array(Set(entries.compactMap(\.platformID))).sorted()
    }
}
