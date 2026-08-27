import Cocoa

/// The app's appearance theme (§3.2): follow the system, or force light or
/// dark. Persisted app-wide and applied to `NSApp.appearance`, so every window
/// (main, settings, sheets, popovers) follows the choice.
///
/// Mirrors the `WordSize` pattern: the value is read live from `UserDefaults`,
/// and `set(_:)` posts `didChangeNotification` so the app can re-apply the
/// theme. "System" is the default and is stored as the empty string.
enum AppTheme: String, CaseIterable {
    /// Follow the system's Light/Dark setting (the default).
    case system = ""
    /// Force the light appearance.
    case light
    /// Force the dark appearance.
    case dark

    static let userDefaultsKey = "AppTheme"

    /// Posted after `set(_:)` so the app re-applies the theme.
    static let didChangeNotification = Notification.Name("AppThemeDidChange")

    /// The currently selected theme, falling back to system.
    static var current: AppTheme {
        let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? system.rawValue
        return AppTheme(rawValue: stored) ?? .system
    }

    /// Persists `theme` and notifies observers to re-apply it.
    static func set(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// Restores the built-in default (system) and notifies.
    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// The `NSAppearance` this theme maps to — nil for system, which lets the
    /// app follow the system setting.
    var appearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    /// The title shown for this theme in the Settings popup.
    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}
