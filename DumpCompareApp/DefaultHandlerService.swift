import Cocoa
import UniformTypeIdentifiers

/// The Launch Services side of the File Types tab (§25): which app opens a file
/// extension by double-click, and asking the system to make that app this one.
///
/// Built on `NSWorkspace`, not on `LSSetDefaultRoleHandlerForContentType`. The
/// classic call is deprecated since macOS 12 and — measured — refuses the write
/// from inside the app sandbox with `permErr` (-54); `setDefaultApplication`
/// performs the same change from the same sandbox with no entitlement and no
/// helper process (§25.1).
///
/// Two asymmetries of the system's own, both load-bearing here:
///
/// - Claiming a type for **this** app goes through without asking. Handing one
///   to **another** app is the user's decision, so macOS puts up its own
///   confirmation and the call comes back with `userCanceledErr` when the user
///   declines. Neither is an error to report as a failure.
/// - The answer is by bundle identifier, not by bundle URL: ask with this
///   build's URL and the system may name the installed copy of the app. Every
///   comparison here is therefore on the identifier (`isSelfDefault`).
///
/// There is no API to *clear* a default — only to point it at some app — which
/// is why unchecking a type hands it back to the handler this app displaced
/// (§25.3).
enum DefaultHandlerService {
    /// This app's bundle, the one the tab offers to make default.
    static var selfBundleURL: URL { Bundle.main.bundleURL }
    static var selfBundleIdentifier: String? { Bundle.main.bundleIdentifier }

    /// The type `ext` resolves to, or nil for a string that is not an extension.
    /// A declared system type for some extensions (`.bin` is
    /// `com.apple.macbinary-archive`), a dynamic `dyn.…` type for the rest —
    /// both work as the subject of a default-handler change, so the tab does not
    /// need an Info.plist entry per extension the user adds.
    static func type(for ext: String) -> UTType? {
        UTType(filenameExtension: ext)
    }

    /// The app that currently opens `ext` on a double-click, or nil when nothing
    /// claims it. Reading is permitted inside the sandbox, which is what lets
    /// the tab show the truth rather than what it last asked for.
    static func currentHandler(for ext: String) -> URL? {
        guard let type = type(for: ext) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    /// The name to show for a handler — "Archive Utility", not a path. Nil for
    /// no handler at all.
    static func handlerName(for ext: String) -> String? {
        guard let url = currentHandler(for: ext) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Whether this app is the current handler for `ext`. Compared by bundle
    /// identifier: the system answers with whichever copy of the app it has
    /// registered, which under Xcode is not the copy that is running.
    static func isSelfDefault(for ext: String) -> Bool {
        guard let url = currentHandler(for: ext), let selfBundleIdentifier else { return false }
        return Bundle(url: url)?.bundleIdentifier == selfBundleIdentifier
    }

    /// The bundle identifier of whoever handles `ext` now — recorded before this
    /// app takes the type over, so unchecking can hand it back (§25.3).
    static func currentHandlerIdentifier(for ext: String) -> String? {
        guard let url = currentHandler(for: ext) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Asks the system to make this app the handler for `ext`. Completes on the
    /// main queue with the system's error, if any — including the user declining
    /// a confirmation, which is a normal outcome (§25.3).
    static func setSelfAsDefault(for ext: String, then completion: @escaping (Error?) -> Void) {
        set(selfBundleURL, for: ext, then: completion)
    }

    /// Asks the system to make the app with `bundleIdentifier` the handler for
    /// `ext` — the restore path. Completes with a `notFound` error when that app
    /// is no longer installed.
    static func setHandler(bundleIdentifier: String, for ext: String,
                           then completion: @escaping (Error?) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            completion(CocoaError(.fileNoSuchFile))
            return
        }
        set(url, for: ext, then: completion)
    }

    private static func set(_ appURL: URL, for ext: String, then completion: @escaping (Error?) -> Void) {
        guard let type = type(for: ext) else {
            completion(CocoaError(.fileReadInvalidFileName))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { error in
            // The completion arrives on an arbitrary queue; the tab it feeds is
            // UI, so hop to the main one here rather than at every call site.
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Whether `error` is the user saying no to the system's confirmation, which
    /// the tab reports as nothing at all — the checkbox simply goes back to what
    /// the system says (§25.3).
    static func isUserCancellation(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.code == NSUserCancelledError { return true }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSOSStatusErrorDomain && underlying?.code == -128
    }
}
