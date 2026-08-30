import Foundation

/// What a document with no file behind it may be called (§23).
///
/// An unsaved document's name is a label rather than a path: the header shows
/// it, the save panel opens pre-filled with it, and Save All as Separate Files
/// builds every piece's file name from it. That last one is why the label has to
/// survive being turned into a file name — a base name with a slash in it does
/// not name a file, it names a directory that is not there.
///
/// Pure, like `DuplicateName`, which produces the names this one has to accept:
/// a rule about names is worth checking without a document, a window or a
/// filesystem.
enum PaneName {
    /// The characters a name cannot carry into a file name: the POSIX path
    /// separator, the Finder's, and the null the filesystem ends a name with.
    private static let forbidden: Set<Character> = ["/", ":", "\0"]

    /// The name `raw` asks for, or nil when it asks for nothing.
    ///
    /// Trimmed at both ends, since trailing space in a header reads as a
    /// mistake and makes a file nobody can tell from its neighbour. Forbidden
    /// characters are dropped rather than the whole name refused: the result
    /// appears in the header the moment the field closes, so the user sees what
    /// was taken and can say it differently. A name that was only whitespace or
    /// only separators asks for nothing, and nothing is what happens — the old
    /// name stays.
    static func sanitized(_ raw: String) -> String? {
        let kept = String(raw.filter { !forbidden.contains($0) })
        let trimmed = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
