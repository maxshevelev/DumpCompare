import Foundation

/// The folder the pattern library is published to, remembered across launches
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// **A folder, not a file.** A sandboxed app is granted what the user pointed
/// at, and a grant on a file dies with that file — every atomic write replaces
/// it, this Mac's, every other Mac's and iCloud's. A folder grant survives all
/// of that, which is the difference between the system asking once and asking
/// at every launch. It also covers what the app has to reach *beside* the
/// library: the copies a sync client leaves when it cannot decide.
///
/// So the user chooses a folder their Mac syncs, and the files inside it are
/// the app's to name.
enum LibraryLocation {
    static let folderBookmarkKey = "LibraryFolderBookmark"
    static let folderPathKey = "LibraryFolderPath"

    /// The keys the location was kept under when it was a file. Read once, to
    /// carry an install that predates the folder over to it.
    static let legacyBookmarkKey = "LibraryPublishedBookmark"
    static let legacyPathKey = "LibraryPublishedPath"

    /// The domain the location lives in — the store's, so a test that isolates
    /// one isolates both.
    static var defaults: UserDefaults { FavoritePatternStore.defaults }

    /// What every library file in the folder is called, before the part that
    /// says which machine wrote it. It is the name a stranger sees, in a folder
    /// among other people's files, where the app's own word for the feature
    /// says nothing and the content has to.
    static let fileStem = "DumpCompare Patterns"
    static let fileExtension = "json"

    /// **One file per machine.** Each Mac writes its own and reads everyone
    /// else's; no file ever has two writers, so there is nothing for a sync
    /// client to arbitrate — no "last write wins", no conflicted copies, and no
    /// version quietly discarded between two machines that were both offline.
    ///
    /// The name is a hash of the machine's id and nothing else. Not its
    /// *hostname*: a laptop takes a new one from whatever network it joins, and
    /// anybody can change one whenever they like — and a file whose name moves
    /// is a machine that starts writing a second file and leaves the first
    /// behind for ever. Not the id itself either: it goes into a folder the
    /// user shares, and a hash identifies the file as well while saying nothing
    /// about the Mac. Which Mac wrote it is *inside* the file, where a changed
    /// name is a changed line rather than a new file.
    static func fileName(for device: String) -> String {
        "\(fileStem) (\(DeviceIdentity.digest(of: device))).\(fileExtension)"
    }

    /// The file *this* machine writes inside `folder`.
    static func file(in folder: URL, device: String? = nil) -> URL {
        folder.appendingPathComponent(fileName(for: device ?? DeviceIdentity.current))
    }

    /// Every machine's library file in `folder`, in a fixed order so two runs
    /// merge the same folder the same way.
    ///
    /// Matched by name rather than by content: a file that cannot be read yet
    /// — a placeholder iCloud has not downloaded — has to be in the list, or
    /// the merge would treat a machine that is present as one that never wrote.
    static func libraryFiles(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isLibraryFile).sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Whether a name is one of this app's library files: a machine's own, and
    /// nothing else.
    ///
    /// One bracketed label, and it has to be a machine's stamp: twelve hex
    /// digits. That is what keeps everything else out of the library — the
    /// copies a sync client leaves ("… (A93F1C0D22B7) 2.json", "… (conflicted
    /// copy 2026-09-05).json") and any file the user named themselves. The app
    /// does not read them, fold them in or remove them: a file it did not write
    /// is the user's to look at.
    static func isLibraryFile(_ name: String) -> Bool {
        guard name.hasSuffix(".\(fileExtension)") else { return false }
        let opening = "\(fileStem) ("
        guard name.hasPrefix(opening), name.hasSuffix(").\(fileExtension)") else { return false }
        let label = name.dropFirst(opening.count).dropLast(").\(fileExtension)".count)
        return label.count == stampLength
            && label.allSatisfy { $0.isHexDigit && !$0.isLowercase }
    }

    /// How long a machine's stamp is, in characters (`DeviceIdentity.digest`).
    static let stampLength = 12

    /// The folder the library is published to, with access already taken.
    /// Nil when the library is kept to this Mac.
    static func restore() -> URL? {
        if let folder = resolveFolder() { return folder }
        return migrateFromFile()
    }

    /// Whether the folder was reached through its bookmark, with access taken.
    ///
    /// False means the app is about to try the *path*, which a sandboxed app
    /// may not use for somebody else's folder — so writing will fail. The
    /// commonest reason is not exotic: a security-scoped bookmark is bound to
    /// the app's code identity, and an **ad-hoc signed** build has a new
    /// identity every time it is built (`CODE_SIGN_IDENTITY: "-"`, so the
    /// identity is the cdhash). Every rebuild therefore throws away every
    /// grant the user has given, and the only way back is to point at the
    /// folder again. A stable signing identity is what ends that, and it is
    /// the same thing iCloud proper needs (`Design/FAVORITES_SYNC_IDEA.md`).
    private(set) static var hasAccess = false

    private static func resolveFolder() -> URL? {
        if let data = defaults.data(forKey: folderBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                hasAccess = url.startAccessingSecurityScopedResource()
                if stale { remember(url) }
                return url
            }
        }
        hasAccess = false
        // The path is the last resort, and the only road on which a protected
        // folder makes the system ask again.
        return defaults.string(forKey: folderPathKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Carries over an install that published to a *file*: the folder it was in
    /// is the folder the library lives in, and its grant is taken afresh the
    /// next time anything is published.
    private static func migrateFromFile() -> URL? {
        guard let path = defaults.string(forKey: legacyPathKey) else { return nil }
        defer {
            defaults.removeObject(forKey: legacyPathKey)
            defaults.removeObject(forKey: legacyBookmarkKey)
        }
        if let data = defaults.data(forKey: legacyBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                let folder = url.deletingLastPathComponent()
                remember(folder)
                return folder
            }
        }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        remember(folder)
        return folder
    }

    /// Remembers `folder` as the place the library is published to.
    ///
    /// Called again after every publish: a bookmark can go stale, and a stale
    /// bookmark sends the next launch down the path. A failure leaves whatever
    /// is already there — throwing away a working permission is the worse of
    /// the two mistakes available.
    static func remember(_ folder: URL) {
        defaults.set(folder.standardizedFileURL.path, forKey: folderPathKey)
        if let data = try? folder.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) {
            defaults.set(data, forKey: folderBookmarkKey)
        }
        // Chosen just now, through a panel: that grant is live whatever the
        // bookmark does later.
        hasAccess = true
    }

    static func forget() {
        hasAccess = false
        defaults.removeObject(forKey: folderBookmarkKey)
        defaults.removeObject(forKey: folderPathKey)
        defaults.removeObject(forKey: legacyBookmarkKey)
        defaults.removeObject(forKey: legacyPathKey)
    }

    /// Whether a bookmark is on file — what says the next launch reaches the
    /// library without the system asking the user again.
    static var hasBookmark: Bool { defaults.data(forKey: folderBookmarkKey) != nil }

    /// Where the panel opens when the library has never been published: iCloud
    /// Drive if the user has it, and their Documents folder otherwise.
    ///
    /// The panel runs out of process, so it may be pointed at a folder this app
    /// cannot read itself — which is exactly the case here, and as close to a
    /// sensible default as a sandboxed app can get without an iCloud
    /// entitlement.
    static func suggestedFolder() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) { return iCloud }
        return home.appendingPathComponent("Documents")
    }
}
