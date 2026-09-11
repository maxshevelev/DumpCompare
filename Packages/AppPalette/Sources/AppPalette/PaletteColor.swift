import AppKit

/// One colour set in the app's catalogue: what it is called there, and the two
/// shades it holds.
///
/// A colour is picked in Xcode's colour editor and read back out of the
/// catalogue by `Scripts/gen-palette.py`, so nothing about a shade is typed by
/// hand. This is the value that read-back produces, and what turns it into the
/// `NSColor` a view draws with: the compiled catalogue's own colour where there
/// is one — the app — and the read-back shades where there is not, which is
/// every package test in this repository (`swift build` copies an `.xcassets`
/// verbatim; only Xcode runs `actool`).
public struct PaletteColor: Sendable {
    public let name: String
    public let light: Shade
    public let dark: Shade

    /// One theme's colour. The alpha is part of it: a difference wash is drawn
    /// over whatever the dump's own layers painted, and how much of that it
    /// lets through is the colour, not a detail of one use of it.
    public typealias Shade = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

    public init(name: String, light: Shade, dark: Shade) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// The colour to draw with.
    public var color: NSColor {
        if let fromCatalogue = catalogued { return fromCatalogue }
        return NSColor(name: nil) { appearance in
            shade(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }

    /// What the compiled catalogue holds for this set, or nil where there is no
    /// compiled catalogue to ask.
    public var catalogued: NSColor? { NSColor(named: name, bundle: .module) }

    /// One theme's shade, as the read-back says it is.
    public func shade(dark: Bool) -> NSColor {
        let it = dark ? self.dark : light
        return NSColor(srgbRed: it.red, green: it.green, blue: it.blue, alpha: it.alpha)
    }
}
