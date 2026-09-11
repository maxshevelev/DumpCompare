import Foundation

/// The name a duplicated pane wears until it is saved (§23).
///
/// A copy used to be called "Untitled", like any document the app made rather
/// than opened — which is true, and useless the moment there are two of them:
/// two panes both called Untitled say nothing about which dump each came from.
/// A copy of `bios.bin` is called `bios-2.bin` instead. Nothing is written to
/// disk; this is a name for the header to show and for the save panel to
/// pre-fill, and the file appears only when the user actually saves.
///
/// A joined image takes a name the same way (§22.2), and for the same reason: it
/// is that dump with something added, and the header, the save panel and Save
/// All as Separate Files all need something to call it.
///
/// Pure, like `OpenPlacement` and `DropBandLayout`: naming is a rule, and a rule
/// is worth checking without a document, a window or a filesystem.
enum DuplicateName {
    /// The name for a copy of `name`, avoiding everything in `taken`.
    ///
    /// A copy of a copy counts on rather than nesting: `bios-2.bin` gives
    /// `bios-3.bin`, not `bios-2-2.bin`. The suffix is a position in a series,
    /// so a series of duplicates reads as one — which is the whole reason for
    /// having it.
    static func next(after name: String, taken: Set<String>) -> String {
        let (stem, suffix) = split(name)
        let (base, start) = seriesStart(of: stem)
        var index = start
        while true {
            let candidate = suffix.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(suffix)"
            if !taken.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// The name without its extension, and the extension.
    ///
    /// Split at the *last* dot, and only when it has something on both sides, so
    /// `bios.v2.bin` keeps `bios.v2` and a dotfile is left whole.
    private static func split(_ name: String) -> (stem: String, suffix: String) {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex,
              dot != name.index(before: name.endIndex) else { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The stem with any `-<number>` series suffix removed, and the number the
    /// series continues from.
    ///
    /// `bios` starts at 2 — the original is the first of its kind, so its copy
    /// is the second. `bios-2` continues at 3. A stem that merely *ends* in a
    /// number without the dash, like `W25Q128`, is not a series: its copy is
    /// `W25Q128-2`, because the digits there are part of the chip's name.
    private static func seriesStart(of stem: String) -> (base: String, next: Int) {
        guard let dash = stem.lastIndex(of: "-"),
              dash != stem.startIndex else { return (stem, 2) }
        let tail = stem[stem.index(after: dash)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber), let number = Int(tail) else {
            return (stem, 2)
        }
        return (String(stem[stem.startIndex..<dash]), number + 1)
    }
}
