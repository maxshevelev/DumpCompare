import Foundation

/// A Sendable value type representing the user's text-decoding preference.
public struct TextDecodingSettings: Equatable, Sendable {
    public let identifier: String
    public let placeholder: Character

    public init(identifier: String, placeholder: Character) {
        self.identifier = identifier
        self.placeholder = placeholder
    }

    public static let `default` = TextDecodingSettings(identifier: "cp1252", placeholder: ".")
}

/// Observable store for text-decoding settings.
///
/// Loads / persists to `UserDefaults`. Publishes changes via
/// `NotificationCenter` so any observer can react. No AppKit dependency.
public final class TextDecodingSettingsStore: @unchecked Sendable {

    public static let identifierKey = "TextDecodingIdentifier"
    public static let placeholderKey = "TextDecodingPlaceholder"

    /// Posted whenever the persisted settings change. The notification's `object`
    /// is the new `TextDecodingSettings` value.
    public static let didChangeNotification = Notification.Name("TextDecodingSettingsDidChange")

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Current settings loaded from persistence. Corrupted or missing values
    /// fall back to defaults (cp1252, ".").
    public var settings: TextDecodingSettings {
        let id = userDefaults.string(forKey: Self.identifierKey)
        let ph = userDefaults.string(forKey: Self.placeholderKey)

        // Validate the identifier: must be a known table.
        let knownIds = TextDecoderRegistry.all.map { $0.identifier }
        let identifier = (id.flatMap { knownIds.contains($0) ? $0 : nil }) ?? TextDecodingSettings.default.identifier

        // Validate the placeholder: exactly one character.
        let placeholder: Character
        if let ph = ph, ph.count == 1 {
            placeholder = ph.first!
        } else {
            placeholder = TextDecodingSettings.default.placeholder
        }

        return TextDecodingSettings(identifier: identifier, placeholder: placeholder)
    }

    /// Apply new settings, persist, and notify.
    public func apply(_ newSettings: TextDecodingSettings) {
        userDefaults.set(newSettings.identifier, forKey: Self.identifierKey)
        userDefaults.set(String(newSettings.placeholder), forKey: Self.placeholderKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: newSettings)
    }

    /// Reset to built-in defaults and notify.
    public func resetToDefaults() {
        userDefaults.removeObject(forKey: Self.identifierKey)
        userDefaults.removeObject(forKey: Self.placeholderKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: TextDecodingSettings.default)
    }
}
