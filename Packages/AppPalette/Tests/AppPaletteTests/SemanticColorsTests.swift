import AppKit
import XCTest
@testable import AppPalette

/// What the palette says, whichever half of it this build is reading. The
/// catalogue is the editable half and the numbers are the portable one; that
/// the two agree is the app suite's test, because only a build that compiles an
/// asset catalogue has one to compare against.
final class SemanticColorsTests: XCTestCase {
    /// Each colour carries both themes, and they are not the same colour: one
    /// variant is one that is illegible in the other theme.
    func testEachColourIsToldApartByTheTheme() throws {
        for definition in SemanticColors.Definition.all {
            let light = definition.shade(dark: false)
            let dark = definition.shade(dark: true)
            XCTAssertNotEqual(light, dark, "\(definition.name) is the same in both themes")
            XCTAssertGreaterThan(dark.brightnessComponent, light.brightnessComponent,
                                 "\(definition.name) is the paler one on a dark ground")
        }
    }

    /// A palette resolves to its own shade for the appearance it is drawn in,
    /// rather than to one of them always.
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
        XCTAssertEqual(inLight.redComponent, SemanticColors.Definition.good.light.red, accuracy: 0.01)
        XCTAssertEqual(inDark.greenComponent, SemanticColors.Definition.good.dark.green, accuracy: 0.01)
    }

    /// The green is the one the ME summary draws "Configured" in, which is the
    /// whole reason the palette was made — spelled out here so a change to it
    /// is a decision rather than an accident.
    func testTheGoodGreenIsTheOneTheSummaryUses() {
        let green = SemanticColors.Definition.good
        XCTAssertEqual(green.light.red, 0.07, accuracy: 0.005)
        XCTAssertEqual(green.light.green, 0.46, accuracy: 0.005)
        XCTAssertEqual(green.light.blue, 0.12, accuracy: 0.005)
    }

    /// Every entry is named, and named once: two entries under one name is a
    /// catalogue lookup that silently answers with the wrong colour.
    func testTheNamesAreDistinct() {
        let names = SemanticColors.Definition.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
    }
}
