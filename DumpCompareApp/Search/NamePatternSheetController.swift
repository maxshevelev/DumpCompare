import Cocoa
import DumpCompareCore

/// Keeps the pattern in the Find bar's field, under a name (§11,
/// `Design/PATTERN_LIBRARY_IDEA.md`).
///
/// The way a library actually fills up: nobody opens Settings to type a pattern
/// from memory, they keep the one that just worked. So the sheet asks for the
/// one thing the bar has not got — a name — and shows what is being kept
/// underneath it, unchangeably: the pattern is already what the user typed, and
/// changing it here would make this a second pattern editor.
///
/// The encoding shown is the popup's, which after a Smart Search is the one
/// that *worked* (§11) — saving right after a successful search is the good
/// case, and it captures the pairing an entry exists to carry.
final class NamePatternSheetController: SheetViewController {
    private let entry: SearchPatternEntry
    private let onKeep: (SearchPatternEntry) -> Void
    private var nameField: NSTextField!

    init(entry: SearchPatternEntry, onKeep: @escaping (SearchPatternEntry) -> Void) {
        self.entry = entry
        self.onKeep = onKeep
        super.init(title: "Add to Favorites", message: Self.describe(entry))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// What is being kept, in the words the menu will use for it.
    private static func describe(_ entry: SearchPatternEntry) -> String {
        let flags = entry.encoding == .hex
            ? entry.encoding.displayName
            : "\(entry.encoding.displayName), "
                + (entry.caseSensitive ? "match case" : "ignore case")
        return "Keeping \"\(entry.pattern)\" — \(flags)."
    }

    override func loadView() {
        super.loadView()
        // Empty rather than pre-filled with the pattern: a name that repeats
        // the pattern is a row that says the same thing twice, and the pattern
        // is already on the line above.
        nameField = addFieldRow(label: "Name:", initial: "")
        submitButton.title = "Add"
    }

    override func firstField() -> NSView? { nameField }

    override func validate() -> String? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name — it is what the menu shows." }
        if !entry.isUsable { return "That pattern cannot be read as \(entry.encoding.displayName)." }
        if let kept = FavoritePatternStore.existing(for: entry) {
            // The same search under two names is two answers to one question,
            // so the sheet says which name it is already kept under and lets
            // the user rename it in the form rather than adding a second row.
            return "Already a favourite, as \"\(kept.name)\"."
        }
        return nil
    }

    override func handleSubmit() {
        var kept = entry
        kept.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onKeep(kept)
    }
}
