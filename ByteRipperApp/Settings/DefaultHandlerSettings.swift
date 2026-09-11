import Foundation

/// The list of file extensions the File Types tab manages (§25.2), persisted in
/// `UserDefaults` — the same shape as `FindHistoryStore`, down to the swappable
/// defaults domain so tests run against a store of their own.
///
/// What is NOT stored here is whether an extension is *registered*: that lives
/// in the system, is read back through `DefaultHandlerService`, and a copy kept
/// here could only go stale — the user can change a default in Finder at any
/// moment and the tab has to show what is true, not what it last asked for
/// (§25.3).
///
/// One thing does have to be remembered: the handler this app displaced. macOS
/// has no API to clear a default, only to point it somewhere, so handing a type
/// back needs the name of who had it before.
enum DefaultHandlerSettings {
    static let userDefaultsKey = "DefaultHandlerFileTypes"

    /// The defaults domain the list lives in. Swappable for tests (§11 does the
    /// same).
    static var defaults: UserDefaults = .standard

    /// The extensions the tab starts with: the two the app is about (§25.2).
    /// Listed, never pre-registered — the first launch must not quietly take
    /// MacBinary from Archive Utility.
    static let builtInExtensions = ["bin", "rom"]

    /// One row of the tab: an extension, and the bundle identifier of the app
    /// that handled it before this one took over (nil when this app never took
    /// it, or when nothing handled it).
    struct Entry: Equatable {
        var ext: String
        var displacedHandler: String?
    }

    private static let extKey = "ext"
    private static let displacedKey = "displaced"

    /// The rows, in the order the user sees them. The built-in list on a store
    /// that has never been written.
    static var entries: [Entry] {
        guard let raw = defaults.array(forKey: userDefaultsKey) as? [[String: Any]] else {
            return builtInExtensions.map { Entry(ext: $0, displacedHandler: nil) }
        }
        return raw.compactMap { item in
            guard let ext = item[extKey] as? String, let normalized = normalize(ext) else { return nil }
            return Entry(ext: normalized, displacedHandler: item[displacedKey] as? String)
        }
    }

    private static func write(_ entries: [Entry]) {
        let raw: [[String: Any]] = entries.map { entry in
            var item: [String: Any] = [extKey: entry.ext]
            if let displaced = entry.displacedHandler { item[displacedKey] = displaced }
            return item
        }
        defaults.set(raw, forKey: userDefaultsKey)
    }

    /// Adds `raw` to the list. Returns the normalized extension when it was
    /// added, or nil when it is not an extension at all — and the extension
    /// itself, unchanged, when the list already carries it: the caller selects
    /// the existing row rather than reporting an error, because "it is already
    /// there" is the answer to what the user asked for.
    @discardableResult
    static func add(_ raw: String) -> String? {
        guard let ext = normalize(raw) else { return nil }
        var list = entries
        guard !list.contains(where: { $0.ext == ext }) else { return ext }
        list.append(Entry(ext: ext, displacedHandler: nil))
        write(list)
        return ext
    }

    static func remove(_ ext: String) {
        write(entries.filter { $0.ext != ext })
    }

    /// Remembers who handled `ext` before this app took it (§25.3). Recorded at
    /// the moment of the change, not read back later: by then the answer is this
    /// app.
    static func recordDisplacedHandler(_ bundleIdentifier: String?, for ext: String) {
        var list = entries
        guard let index = list.firstIndex(where: { $0.ext == ext }) else { return }
        list[index].displacedHandler = bundleIdentifier
        write(list)
    }

    static func displacedHandler(for ext: String) -> String? {
        entries.first { $0.ext == ext }?.displacedHandler
    }

    /// Forgets the displaced handler for `ext` — after it has been handed back,
    /// so a second uncheck does not try again.
    static func clearDisplacedHandler(for ext: String) {
        recordDisplacedHandler(nil, for: ext)
    }

    static func resetToDefaults() {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// A file extension as Launch Services understands one: no leading dot, no
    /// surrounding space, lower case. Nil for anything that cannot be an
    /// extension — empty, or carrying a separator or a character that would make
    /// it a path or a glob rather than a suffix.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        value = value.lowercased()
        guard !value.isEmpty, value.count <= 32 else { return nil }
        // Letters and digits only: an extension with a slash, a dot or a star in
        // it is a path or a pattern, and Launch Services would not take it.
        guard value.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return value
    }
}
