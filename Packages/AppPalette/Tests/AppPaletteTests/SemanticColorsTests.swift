import AppKit
import XCTest
@testable import AppPalette

/// What each family of the palette must be true of whatever colours are picked
/// in it — the rules, not the shades. A colour is chosen in Xcode's colour
/// editor, so a test that pinned a number would mean a code change every time
/// somebody picked a better green, which is exactly the friction the catalogue
/// exists to remove.
///
/// That the catalogue and the numbers read back out of it agree is the app
/// suite's test (`SemanticPaletteTests`): only a build that compiles an asset
/// catalogue has one to compare against.
final class SemanticColorsTests: XCTestCase {
    /// A semantic colour is *text*, so its dark shade is the paler one: a shade
    /// tuned for white paper is illegible on near-black.
    func testASemanticColourIsPalerOnADarkGround() {
        for set in SemanticColors.Sets.all {
            XCTAssertGreaterThan(set.shade(dark: true).brightnessComponent,
                                 set.shade(dark: false).brightnessComponent,
                                 "\(set.name) is not the paler one on a dark ground")
        }
    }

    /// A segment tint is a *background*, so the rule is the other way round: a
    /// pastel that sits barely off white paper has to sit barely off near-black
    /// in the other theme, or a piece's tint becomes a highlight.
    func testASegmentTintIsDarkerOnADarkGround() {
        for set in SegmentTints.Sets.all {
            XCTAssertLessThan(set.shade(dark: true).brightnessComponent,
                              set.shade(dark: false).brightnessComponent,
                              "\(set.name) is not the darker one on a dark ground")
        }
    }

    /// And neighbouring tints are plainly different, because that difference is
    /// what draws the boundary between one piece and the next.
    func testNeighbouringSegmentTintsAreToldApart() throws {
        for dark in [false, true] {
            let shades = SegmentTints.Sets.all.map { $0.shade(dark: dark).usingColorSpace(.sRGB) }
            for (index, pair) in zip(shades, shades.dropFirst()).enumerated() {
                let first = try XCTUnwrap(pair.0)
                let next = try XCTUnwrap(pair.1)
                let apart = abs(first.redComponent - next.redComponent)
                    + abs(first.greenComponent - next.greenComponent)
                    + abs(first.blueComponent - next.blueComponent)
                XCTAssertGreaterThan(apart, 0.08,
                                     "S\(index) and S\(index + 1) are near-identical in "
                                         + (dark ? "dark" : "light"))
            }
        }
    }

    /// A difference is a wash over the dump's own layers, so it has to let them
    /// through: an opaque fill would hide the byte it is marking.
    func testTheDifferenceFillIsAWash() {
        for set in DifferenceColors.Sets.all {
            for dark in [false, true] {
                let alpha = dark ? set.dark.alpha : set.light.alpha
                XCTAssertLessThan(alpha, 0.8, "\(set.name) covers the bytes under it")
                XCTAssertGreaterThan(alpha, 0.1, "\(set.name) is too faint to read as a fill")
            }
        }
    }

    /// A zone outline is drawn over whatever the dump painted, so the two are
    /// told apart by hue rather than by theme — and they must be told apart,
    /// since one says "the node you are looking at" and the other "still part
    /// of the same map".
    func testTheTwoZoneOutlinesAreToldApart() throws {
        let focused = try XCTUnwrap(ZoneColors.Sets.focused.shade(dark: false).usingColorSpace(.sRGB))
        let other = try XCTUnwrap(ZoneColors.Sets.other.shade(dark: false).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(abs(focused.hueComponent - other.hueComponent), 0.1,
                             "the focused zone and the rest are the same hue")
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
        XCTAssertEqual(inLight.redComponent, SemanticColors.Sets.good.light.red, accuracy: 0.01)
        XCTAssertEqual(inDark.greenComponent, SemanticColors.Sets.good.dark.green, accuracy: 0.01)
    }

    /// A tint is asked for by the piece's index, and a partition can have more
    /// pieces than the palette has tints.
    func testTheTintsCycleByIndex() {
        let count = SegmentTints.all.count
        XCTAssertEqual(SegmentTints.tint(at: 0), SegmentTints.all.first)
        XCTAssertEqual(SegmentTints.tint(at: count), SegmentTints.all.first,
                       "one past the last is the first again")
        XCTAssertEqual(SegmentTints.tint(at: -1), SegmentTints.all.last,
                       "and it does not trap on a negative index")
    }

    /// Every colour set is named once: two under one name is a catalogue lookup
    /// that quietly answers with the wrong colour.
    func testTheNamesAreDistinct() {
        let names = SemanticColors.everySet.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        XCTAssertFalse(names.isEmpty, "the catalogue was read back into nothing")
    }
}
