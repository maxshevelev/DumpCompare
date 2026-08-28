import Cocoa
import CoreServices
import UniformTypeIdentifiers

/// The Launch Services wrapper behind the File Types tab (§22): makes
/// DumpCompare the *default* viewer for a file extension — the programmatic
/// equivalent of Finder's "Open With… > Change All…" — and can hand the default
/// back to whoever had it before.
///
/// Two calls bracket every change: `LSCopyDefaultRoleHandlerForContentType`
/// reads the current default viewer, `LSSetDefaultRoleHandlerForContentType`
/// writes the override. Both speak in UTIs, and `.bin`/`.rom` have no stable
/// declared UTI, so the type is resolved on the fly from the extension —
/// `UTType(filenameExtension:)` answers for any extension the user adds, with no
/// Info.plist entry needed.
enum DefaultHandlerService {
    /// The role the app claims for a type — a viewer, matching the
    /// `CFBundleTypeRole: Viewer` the app declares in Info.plist.
    static let role = LSRolesMask.viewer

    /// The bundle id Launch Services records as the handler — the app's own.
    static var bundleIdentifier: String? { Bundle.main.bundleIdentifier }

    /// The UTI `ext` resolves to, or nil for a string Launch Services cannot
    /// name as an extension (empty, or something that is not one).
    static func type(for ext: String) -> UTType? {
        UTType(filenameExtension: ext)
    }

    /// The bundle id currently recorded as the default viewer for `ext`, or nil
    /// when no default is set. Captured before the app takes over, so it can be
    /// restored when the user unchecks the type.
    static func currentHandler(for ext: String) -> String? {
        guard let type = type(for: ext) else { return nil }
        return LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, role)?
            .takeRetainedValue() as String?
    }

    /// Makes this app the default viewer for `ext`. Idempotent — re-asserting a
    /// type that already points here is a harmless no-op, which is what makes
    /// re-applying the list at every launch safe. `paramErr` when the extension
    /// does not resolve or the app has no bundle id; `noErr` on success.
    @discardableResult
    static func setSelfAsDefault(for ext: String) -> OSStatus {
        guard let type = type(for: ext), let bundleIdentifier else { return OSStatus(paramErr) }
        return LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, role,
                                                     bundleIdentifier as CFString)
    }

    /// Restores `previous` as the default viewer for `ext` — the handler the
    /// app displaced. With no previous handler there is nothing to put back, so
    /// the call is skipped: there is no API to *clear* a default override, only
    /// to overwrite it with another bundle id.
    static func restoreDefault(for ext: String, to previous: String?) -> OSStatus {
        guard let previous, let type = type(for: ext) else { return OSStatus(noErr) }
        return LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, role,
                                                     previous as CFString)
    }
}
