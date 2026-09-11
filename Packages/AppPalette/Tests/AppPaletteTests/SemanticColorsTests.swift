import AppKit
import XCTest
@testable import AppPalette

/// What the palette must be true of whatever colours are picked in it — the
/// rules, not the shades. A colour is chosen in Xcode's colour editor, so a
/// test that pinned a number would mean a code change every time somebody
/// picked a better green, which is exactly the friction the catalogue exists to
/// remove.
///
/// That the catalogue and the numbers read back out of it agree is the app
/// suite's test (`SemanticPaletteTests`): only a build that compiles an asset
/// catalogue has one to compare against.
final class SemanticColorsTests: XCTestCase {
    /// Each colour carries both themes, and the dark one is the paler: a shade
    /// tuned for white paper is illegible on near-black, which is the one thing
    /// a palette must not let through.
    func testEachColourIsToldApartByTheTheme() {
        for definition in SemanticColors.Definition.all {
            let light = definition.shade(dark: false)
            let dark = definition.shade(dark: true)
            XCTAssertNotEqual(light, dark, "\(definition.name) is the same in both themes")
            XCTAssertGreaterThan(dark.brightnessComponent, light.brightnessComponent,
                                 "\(definition.name) is the paler one on a dark ground")
        }
    }

    /// A palette colour resolves to its own shade for the appearance it is
    /// drawn in, rather than to one of them always.
    func testAPaletteColourFollowsTheAppearanceItIsDrawnIn() throws {
        var light: NSColor?
        var dark: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            light = SemanticColors.good.usingColorSpace(.sRGB)
        }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            dark = SemanticColors.good.usingColorSpace(.sRGB)
        }

        let inLight = try XCTUnwrap(light)
        let inDark = try XCTUnwrap(dark)
        XCTAssertEqual(inLight.redComponent, SemanticColors.Definition.good.light.red,
                       accuracy: 0.01)
        XCTAssertEqual(inDark.greenComponent, SemanticColors.Definition.good.dark.green,
                       accuracy: 0.01)
    }

    /// Every meaning the app names has a colour set behind it, and every colour
    /// set is named once: two under one name is a catalogue lookup that quietly
    /// answers with the wrong colour.
    func testTheNamesAreDistinct() {
        let names = SemanticColors.Definition.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        XCTAssertFalse(names.isEmpty, "the catalogue was read back into nothing")
    }

    /// The three meanings the app draws with are all in the catalogue — so a
    /// colour set renamed in the editor and not regenerated is caught here
    /// rather than by a control drawn in the wrong colour.
    func testTheMeaningsTheAppNamesAreAllInTheCatalogue() {
        let names = Set(SemanticColors.Definition.all.map(\.name))
        for definition in [SemanticColors.Definition.good,
                           .caution, .bad] {
            XCTAssertTrue(names.contains(definition.name), definition.name)
        }
    }
}
