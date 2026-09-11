import AppKit

/// The app's palette of *meanings*: the closed set of colours anything in the
/// app is allowed to say something with, and the one place each is chosen.
///
/// Colour is the fastest thing a reader takes in, and a panel that invents its
/// own green says something subtly different from the panel beside it. These
/// had drifted already — one panel's "this is right" was a hand-mixed green,
/// another's was `systemGreen`, and the two were not the same green on screen —
/// so the choice is made once and a caller picks a meaning rather than a
/// colour.
///
/// **Where a colour is chosen:** `Colors.xcassets` beside this file, as a
/// colour set per meaning, in Xcode's own editor with both appearances side by
/// side. Nothing here is typed by hand — `Palette+Generated.swift` is read back
/// out of those colour sets by `Scripts/gen-palette.py`, and exists only
/// because `swift build` copies an `.xcassets` verbatim rather than compiling
/// it: the app, built by Xcode, reads the catalogue itself, while every package
/// test in this repository reads the generated numbers. The app suite's
/// `SemanticPaletteTests` holds the two to each other.
///
/// **Adding one:** a colour set in the catalogue, a run of
/// `Scripts/gen-palette.py`, and a line below giving the meaning a name. The
/// value is the catalogue's; the meaning is Swift's.
///
/// What is *not* here: the dump's own fills. A differing byte's orange and a
/// modified byte's red are the comparison model's vocabulary rather than a
/// state of some value, they are backgrounds rather than text, and they are
/// built from system colours the platform tunes per release (`HexView.Colors`).
public enum SemanticColors {
    /// A state that is as it should be: a check that passed, a permission that
    /// is granted, a firmware that is configured.
    public static let good = colour(.good)

    /// A state that is neither right nor wrong: something mid-flight, or a
    /// value that wants a second look before it is trusted.
    public static let caution = colour(.caution)

    /// A state that is wrong: a checksum that does not check out, a permission
    /// that is refused, a read that failed.
    public static let bad = colour(.bad)

    /// A value that says nothing about itself — the ordinary case, and what
    /// most values should be. The system's own, so it follows the accessibility
    /// settings the app has no business second-guessing.
    public static let plain = NSColor.labelColor

    /// The label beside a value, and anything else that is there to be read
    /// second.
    public static let quiet = NSColor.secondaryLabelColor

    /// One colour set: its name in the catalogue and its two shades. The values
    /// come from `Palette+Generated.swift`, which is the catalogue read back.
    public struct Definition: Sendable {
        public let name: String
        public let light: (red: CGFloat, green: CGFloat, blue: CGFloat)
        public let dark: (red: CGFloat, green: CGFloat, blue: CGFloat)

        public init(name: String,
                    light: (red: CGFloat, green: CGFloat, blue: CGFloat),
                    dark: (red: CGFloat, green: CGFloat, blue: CGFloat)) {
            self.name = name
            self.light = light
            self.dark = dark
        }

        /// The shade for one theme, as the colour it is.
        public func shade(dark: Bool) -> NSColor {
            let it = dark ? self.dark : light
            return NSColor(srgbRed: it.red, green: it.green, blue: it.blue, alpha: 1)
        }
    }

    /// Whether this build is reading the compiled catalogue rather than the
    /// numbers read back out of it. True in the app, false under `swift test`.
    public static var isFromCatalogue: Bool {
        catalogued(.good) != nil
    }

    /// What the compiled catalogue holds for `definition`, or nil where there
    /// is no compiled catalogue to ask.
    public static func catalogued(_ definition: Definition) -> NSColor? {
        NSColor(named: definition.name, bundle: .module)
    }

    /// The catalogue's colour, or the same colour built from what was read out
    /// of it.
    private static func colour(_ definition: Definition) -> NSColor {
        if let fromCatalogue = catalogued(definition) { return fromCatalogue }
        return NSColor(name: nil) { appearance in
            definition.shade(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}
