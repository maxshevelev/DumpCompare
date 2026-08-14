import Foundation

/// Display word size (§6): the hex dump groups its bytes into words of this
/// many bytes, separating words with spaces. One byte — today's byte-per-cell
/// dump — is the default. Persisted app-wide; both panes share it.
enum WordSize: Int, CaseIterable {
    case one = 1
    case two = 2
    case four = 4
    case eight = 8

    static let userDefaultsKey = "HexWordSize"

    /// Posted after `set(_:)` so open hex views re-lay out.
    static let didChangeNotification = Notification.Name("HexWordSizeDidChange")

    /// The currently selected word size, falling back to one byte.
    static var current: WordSize {
        WordSize(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .one
    }

    /// Persists `size` and notifies observers to re-lay out (§6).
    static func set(_ size: WordSize) {
        UserDefaults.standard.set(size.rawValue, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
