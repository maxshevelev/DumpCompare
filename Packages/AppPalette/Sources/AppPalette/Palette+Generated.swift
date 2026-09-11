// GENERATED from `Colors.xcassets` beside this file.
//
// Regenerate with `Scripts/gen-palette.py`, which re-reads the colour sets
// and rewrites this one. Do not edit by hand: a colour is picked in Xcode's
// colour editor, and the next regeneration overwrites whatever is typed here.
//
// Why it exists at all: `swift build` copies an `.xcassets` verbatim instead
// of compiling it — only Xcode runs `actool` — so a package test would see no
// colours. These are the same numbers, readable without a compiled catalogue.
public extension SemanticColors.Definition {
    static let bad = SemanticColors.Definition(
        name: "SemanticBad",
        light: (0.893, 0.120, 0.120),
        dark: (1.000, 0.420, 0.400))

    static let caution = SemanticColors.Definition(
        name: "SemanticCaution",
        light: (0.807, 0.540, 0.161),
        dark: (0.860, 0.660, 0.360))

    static let good = SemanticColors.Definition(
        name: "SemanticGood",
        light: (0.070, 0.686, 0.120),
        dark: (0.550, 0.820, 0.400))

    /// Every colour set in the catalogue, in the order it names them.
    static let all = [bad, caution, good]
}
