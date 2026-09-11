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
/// **Where the values live.** Twice, deliberately, and a test keeps the two
/// honest:
///
/// - `Colors.xcassets` beside this file is where a colour is *edited* — Xcode's
///   own colour editor, both appearances side by side, which is where picking a
///   colour belongs. Xcode compiles it into the bundle this reads.
/// - The numbers below are the same colours as code, and they are what a build
///   without a compiled catalogue sees. `swift build` copies an `.xcassets`
///   verbatim rather than compiling it, so every package test in this repository
///   runs on these; the app, built by Xcode, runs on the catalogue.
///
/// `SemanticColorsTests` pins what the code says; the app suite's
/// `SemanticPaletteTests` pins that the catalogue says the same thing. Editing
/// one without the other fails.
///
/// What is *not* here: the dump's own fills. A differing byte's orange and a
/// modified byte's red are the comparison model's vocabulary rather than a
/// state of some value, they are backgrounds rather than text, and they are
/// built from system colours the platform tunes per release (`HexView.Colors`).
public enum SemanticColors {
    /// A state that is as it should be: a check that passed, a permission that
    /// is granted, a firmware that is configured.
    public static let good = colour(Definition.good)

    /// A state that is neither right nor wrong: something mid-flight, or a
    /// value that wants a second look before it is trusted.
    public static let caution = colour(Definition.caution)

    /// A state that is wrong: a checksum that does not check out, a permission
    /// that is refused, a read that failed.
    public static let bad = colour(Definition.bad)

    /// A value that says nothing about itself — the ordinary case, and what
    /// most values should be. The system's own, so it follows the accessibility
    /// settings the app has no business second-guessing.
    public static let plain = NSColor.labelColor

    /// The label beside a value, and anything else that is there to be read
    /// second.
    public static let quiet = NSColor.secondaryLabelColor

    /// One palette entry: its name in the catalogue and its two shades. Public
    /// because the test that the catalogue agrees with the code needs both
    /// halves, and because a reader asking "what *is* our green" should find a
    /// number rather than a picker.
    public struct Definition: Sendable {
        public let name: String
        public let light: (red: CGFloat, green: CGFloat, blue: CGFloat)
        public let dark: (red: CGFloat, green: CGFloat, blue: CGFloat)

        public static let good = Definition(
            name: "SemanticGood",
            light: (0.07, 0.46, 0.12), dark: (0.55, 0.82, 0.40))
        public static let caution = Definition(
            name: "SemanticCaution",
            light: (0.55, 0.34, 0.04), dark: (0.86, 0.66, 0.36))
        public static let bad = Definition(
            name: "SemanticBad",
            light: (0.72, 0.12, 0.12), dark: (1.00, 0.42, 0.40))

        public static let all = [good, caution, bad]

        public func shade(dark: Bool) -> NSColor {
            let it = dark ? self.dark : light
            return NSColor(srgbRed: it.red, green: it.green, blue: it.blue, alpha: 1)
        }
    }

    /// Whether this build is reading the compiled catalogue rather than the
    /// numbers above. True in the app, false under `swift test`.
    public static var isFromCatalogue: Bool {
        NSColor(named: Definition.good.name, bundle: .module) != nil
    }

    /// What the catalogue holds for `definition`, or nil where there is no
    /// compiled catalogue to ask.
    public static func catalogued(_ definition: Definition) -> NSColor? {
        NSColor(named: definition.name, bundle: .module)
    }

    /// The catalogue's colour, or the same colour built from the numbers above.
    private static func colour(_ definition: Definition) -> NSColor {
        if let fromCatalogue = catalogued(definition) { return fromCatalogue }
        return NSColor(name: nil) { appearance in
            definition.shade(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}
