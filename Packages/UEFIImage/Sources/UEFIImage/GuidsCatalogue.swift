import Foundation

/// The UEFI GUID catalogue: a GUID and the name the community has given it.
///
/// Half of what a tree shows is a lookup: a volume's file system, a file's
/// identity, a section's definition are GUIDs, and the same GUID means the same
/// thing in every image. This is the big, living catalogue UEFITool keeps on
/// GitHub — hundreds of names the hard-coded `KnownGUIDs` table only sketches —
/// and the structure tree names a node by it when it can.
public struct GuidsCatalogue: Sendable, Equatable {
    /// The names, keyed by GUID. A GUID with no name is simply absent.
    public var names: [EFIGUID: String]

    public init(names: [EFIGUID: String]) {
        self.names = names
    }

    /// The name a GUID has in this catalogue, or nil when the catalogue has
    /// none for it — the caller then shows the GUID itself.
    public func name(of guid: EFIGUID) -> String? {
        names[guid]
    }
}

extension GuidsCatalogue {
    /// The empty catalogue: what the tree shows before a download has landed.
    /// A node with a GUID then shows the GUID itself, and the names fill in
    /// once a fresh `common/guids.csv` arrives.
    public static let empty: GuidsCatalogue = GuidsCatalogue(names: [:])

    /// Parse a `common/guids.csv`: homogeneous `UUID,Name` lines, no header, no
    /// quoting. A line that is not a GUID and a name is skipped, not an error —
    /// a trailing blank line is not worth failing a catalogue over. The name is
    /// everything after the first comma, so a name that itself contains a comma
    /// survives.
    public static func parse(_ data: Data) -> GuidsCatalogue {
        guard let text = String(data: data, encoding: .utf8) else {
            return GuidsCatalogue(names: [:])
        }
        var names: [EFIGUID: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let guid = EFIGUID(String(parts[0]).trimmingCharacters(in: .whitespaces))
            else { continue }
            let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            names[guid] = name
        }
        return GuidsCatalogue(names: names)
    }
}
