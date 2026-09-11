import AppKit

/// The app's palette of *meanings*: the closed set of colours anything in the
/// app is allowed to say something with, and the one place each is chosen.
///
/// Colour is the fastest thing a reader takes in, and a panel that invents its
/// own green says something subtly different from the panel beside it. These
/// had drifted already — one panel's "this is right" was a hand-mixed green,
/// another's was `systemGreen`, and the two were not the same green on screen —
/// so the choice is made once, here, and a caller picks a meaning rather than a
/// colour.
///
/// Each is a dynamic colour: saturated and dark enough to read on white, pale
/// and bright enough to read on near-black, because the app has both themes and
/// a colour tuned for one is illegible in the other.
///
/// What is *not* here: the dump's own fills. A differing byte's orange and a
/// modified byte's red are the comparison model's vocabulary rather than a
/// state of some value, they are backgrounds rather than text, and they live
/// with the grid that draws them (`HexView.Colors`).
public enum SemanticColors {
    /// A state that is as it should be: a check that passed, a permission that
    /// is granted, a firmware that is configured.
    public static let good = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.55, green: 0.82, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.07, green: 0.46, blue: 0.12, alpha: 1)
    }

    /// A state that is neither right nor wrong: something mid-flight, or a
    /// value that wants a second look before it is trusted.
    public static let caution = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 0.86, green: 0.66, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.34, blue: 0.04, alpha: 1)
    }

    /// A state that is wrong: a checksum that does not check out, a permission
    /// that is refused, a read that failed.
    public static let bad = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.12, blue: 0.12, alpha: 1)
    }

    /// A value that says nothing about itself — the ordinary case, and the
    /// thing most values should be.
    public static let plain = NSColor.labelColor

    /// The label beside a value, and anything else that is there to be read
    /// second.
    public static let quiet = NSColor.secondaryLabelColor

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
