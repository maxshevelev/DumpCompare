// GENERATED from `Colors.xcassets` beside this file.
//
// Regenerate with `Scripts/gen-palette.py`, which re-reads the colour sets
// and rewrites this one. Do not edit by hand: a colour is picked in Xcode's
// colour editor, and the next regeneration overwrites whatever is typed here.
//
// Why it exists at all: `swift build` copies an `.xcassets` verbatim instead
// of compiling it — only Xcode runs `actool` — so a package test would see no
// colours. These are the same numbers, readable without a compiled catalogue.

public extension SemanticColors.Sets {
    static let bad = PaletteColor(
        name: "SemanticBad",
        light: (0.893, 0.120, 0.120, 1.000),
        dark: (1.000, 0.420, 0.400, 1.000))

    static let caution = PaletteColor(
        name: "SemanticCaution",
        light: (0.807, 0.540, 0.161, 1.000),
        dark: (0.860, 0.660, 0.360, 1.000))

    static let good = PaletteColor(
        name: "SemanticGood",
        light: (0.070, 0.686, 0.120, 1.000),
        dark: (0.550, 0.820, 0.400, 1.000))

    /// Every semantic colour set in the catalogue, in its own order.
    static let all = [bad, caution, good]
}

public extension ZoneColors.Sets {
    static let focused = PaletteColor(
        name: "ZoneFocused",
        light: (0.349, 0.678, 0.769, 1.000),
        dark: (0.416, 0.769, 0.863, 1.000))

    static let other = PaletteColor(
        name: "ZoneOther",
        light: (0.855, 0.835, 0.329, 1.000),
        dark: (0.855, 0.835, 0.329, 1.000))

    /// Every zone colour set in the catalogue, in its own order.
    static let all = [focused, other]
}

public extension SegmentTints.Sets {
    static let segment0 = PaletteColor(
        name: "Segment0",
        light: (0.840, 0.940, 0.840, 1.000),
        dark: (0.160, 0.250, 0.170, 1.000))

    static let segment1 = PaletteColor(
        name: "Segment1",
        light: (0.970, 0.850, 0.880, 1.000),
        dark: (0.290, 0.170, 0.210, 1.000))

    static let segment2 = PaletteColor(
        name: "Segment2",
        light: (0.840, 0.900, 0.980, 1.000),
        dark: (0.160, 0.220, 0.300, 1.000))

    static let segment3 = PaletteColor(
        name: "Segment3",
        light: (0.980, 0.950, 0.800, 1.000),
        dark: (0.290, 0.270, 0.150, 1.000))

    static let segment4 = PaletteColor(
        name: "Segment4",
        light: (0.890, 0.850, 0.970, 1.000),
        dark: (0.230, 0.190, 0.310, 1.000))

    static let segment5 = PaletteColor(
        name: "Segment5",
        light: (0.990, 0.890, 0.820, 1.000),
        dark: (0.310, 0.230, 0.160, 1.000))

    /// Every segment colour set in the catalogue, in its own order.
    static let all = [segment0, segment1, segment2, segment3, segment4, segment5]
}

public extension DifferenceColors.Sets {
    static let fill = PaletteColor(
        name: "DifferenceFill",
        light: (1.000, 0.584, 0.000, 0.350),
        dark: (1.000, 0.624, 0.039, 0.450))

    /// Every difference colour set in the catalogue, in its own order.
    static let all = [fill]
}
