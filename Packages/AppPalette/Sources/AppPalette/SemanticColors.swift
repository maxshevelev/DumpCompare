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
/// side. Nothing here is a number — `Sets` is those colour sets read back out
/// by `Scripts/gen-palette.py`, and each line below gives one of them the name
/// a caller uses. The value is the catalogue's; the meaning is Swift's.
///
/// The other families are the same arrangement for colours that are not states:
/// `ZoneColors`, `SegmentTints` and `DifferenceColors`.
public enum SemanticColors {
    /// The colour sets, generated. `SemanticColors.Sets.good` is the set;
    /// `SemanticColors.good` is the colour a view draws with.
    public enum Sets {}

    /// A state that is as it should be: a check that passed, a permission that
    /// is granted, a firmware that is configured.
    public static let good = Sets.good.color

    /// A state that is neither right nor wrong: something mid-flight, or a
    /// value that wants a second look before it is trusted.
    public static let caution = Sets.caution.color

    /// A state that is wrong: a checksum that does not check out, a permission
    /// that is refused, a read that failed.
    public static let bad = Sets.bad.color

    /// A value that says nothing about itself — the ordinary case, and what
    /// most values should be. The system's own, so it follows the accessibility
    /// settings the app has no business second-guessing.
    public static let plain = NSColor.labelColor

    /// The label beside a value, and anything else that is there to be read
    /// second.
    public static let quiet = NSColor.secondaryLabelColor

    /// Whether this build is reading the compiled catalogue rather than the
    /// numbers read back out of it. True in the app, false under `swift test`.
    public static var isFromCatalogue: Bool { Sets.good.catalogued != nil }

    /// Every colour set the palette holds, whatever family it is in — what the
    /// app suite checks the catalogue against.
    public static var everySet: [PaletteColor] {
        Sets.all + ZoneColors.Sets.all + SegmentTints.Sets.all + DifferenceColors.Sets.all
    }
}

/// The outlines a tool-module's zones are drawn with over the dump
/// (`Design/TOOL_MODULES_PLAN.md`).
///
/// Deliberately not the accent colour: the accent already means "this is where
/// you are" — the caret's link, the mirror of the other pane — and a zone is
/// something the file *has*, not something the user is doing.
public enum ZoneColors {
    public enum Sets {}

    /// The zone in focus: the node the panel is showing.
    public static let focused = Sets.focused.color

    /// The rest of the map around it — still part of the same structure. Its
    /// colour set carries the same shade in both themes on purpose: it is drawn
    /// over whatever the dump's own layers painted, so it answers to the bytes
    /// under it rather than to the window's theme.
    public static let other = Sets.other.color
}

/// The tints a partition's pieces are drawn in, cycled by label (§21.3): S0,
/// S1, S2… A small set of pastels — enough colour to tell one piece from the
/// next, never enough to draw the eye.
///
/// One order, two sets: the light-theme shades sit barely off the paper and the
/// dark-theme ones are the same hues at the other end of the lightness range,
/// so S1 is "the pink one" in both. They are backgrounds rather than text,
/// which is why their dark shades are the *darker* ones — the opposite of a
/// semantic colour's.
public enum SegmentTints {
    public enum Sets {}

    /// The tints in label order.
    public static let all = Sets.all.map(\.color)

    /// The tint for the piece at `index`, wrapping when a partition has more
    /// pieces than the palette has tints.
    public static func tint(at index: Int) -> NSColor {
        all[((index % all.count) + all.count) % all.count]
    }
}

/// The comparison's own fills: what the app paints on a byte because of what
/// the *other* file says about it (§6).
public enum DifferenceColors {
    public enum Sets {}

    /// A byte that differs from the other pane's. A wash rather than a solid:
    /// its alpha is part of the colour, because the byte's own text and the
    /// piece's tint have to stay readable under it.
    public static let fill = Sets.fill.color
}
