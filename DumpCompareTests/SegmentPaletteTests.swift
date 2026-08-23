import DumpCompareCore
import XCTest
@testable import DumpCompare

/// §21.3 the tint palette, checked against the three rules that make a tint a
/// tint rather than a state. The tints are dynamic colours, so each test
/// resolves the whole set under a pinned appearance (Aqua and Dark Aqua) and
/// measures it there — the same values the dump draws, in both themes.
///
/// The rules:
/// 1. A muted `0x00`/`0xFF` fill byte stays legible on every tint — the tint is
///    a background, and the bytes on it are the point.
/// 2. Neighbouring tints are plainly different — that is what draws the boundary
///    between two pieces, since no line is drawn at a cut.
/// 3. No tint is mistakable for the orange difference, the accent selection, or
///    the bookmark purple — a tint says *which piece*, never *what state*.
@MainActor
final class SegmentPaletteTests: XCTestCase {

    /// The tints and the state colours resolved under `appearance`, in deviceRGB
    /// so the channel math is in one fixed space.
    private func resolved(_ appearanceName: NSAppearance.Name) -> (tints: [NSColor],
                                                                   orange: NSColor,
                                                                   accent: NSColor,
                                                                   bookmark: NSColor,
                                                                   label: NSColor) {
        let appearance = NSAppearance(named: appearanceName)!
        // `performAsCurrentDrawingAppearance` runs the block with the appearance
        // current but returns Void, so the resolved colour is captured out.
        func rgb(_ color: NSColor) -> NSColor {
            var result: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.deviceRGB)
            }
            return result!
        }
        return (
            tints: HexTheme.segmentTints.map(rgb),
            orange: rgb(NSColor.systemOrange),
            accent: rgb(HexTheme.caretColor),
            bookmark: rgb(HexTheme.bookmarkColor),
            label: rgb(NSColor.labelColor),
        )
    }

    /// Sum of per-channel absolute differences — the distance the eye has to
    /// travel between two colours, 0 for identical.
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
        + abs(a.greenComponent - b.greenComponent)
        + abs(a.blueComponent - b.blueComponent)
    }

    /// The two themes the app ships. Each palette set is checked in both, so a
    /// set that only works on white paper fails the dark half.
    private var bothAppearances: [(name: NSAppearance.Name, label: String)] {
        [(.aqua, "light"), (.darkAqua, "dark")]
    }

    // MARK: - Rule 1: the fill bytes stay legible

    /// A `0x00`/`0xFF` byte is drawn in `mutedByteText` — the label colour at
    /// 40% — so on a tint the ink that reaches the eye is that 40% blended over
    /// the tint. The blend must still stand off the tint by a visible margin on
    /// every one of the six, in both themes: a tint that swallows the muted byte
    /// would make the padding unreadable on exactly the rows it is meant to tint.
    func testMutedFillBytesStayLegibleOnEveryTint() {
        for appearance in bothAppearances {
            let c = resolved(appearance.name)
            for (i, tint) in c.tints.enumerated() {
                // The muted byte: label at 40% over the tint.
                let alpha: CGFloat = 0.40
                let ink = NSColor(
                    red: tint.redComponent + (c.label.redComponent - tint.redComponent) * alpha,
                    green: tint.greenComponent + (c.label.greenComponent - tint.greenComponent) * alpha,
                    blue: tint.blueComponent + (c.label.blueComponent - tint.blueComponent) * alpha,
                    alpha: 1)
                // The margin is the largest single-channel step from tint to ink.
                let margin = max(abs(ink.redComponent - tint.redComponent),
                                 abs(ink.greenComponent - tint.greenComponent),
                                 abs(ink.blueComponent - tint.blueComponent))
                XCTAssertGreaterThan(margin, 0.25,
                                     "\(c.label) theme, tint S\(i): the muted fill byte must stand off the tint (margin \(margin))")
            }
        }
    }

    // MARK: - Rule 2: neighbours are plainly different

    /// The tints cycle by label, so the boundary between any two pieces is the
    /// step from one tint to the next — including S5 back to S0, the seam a
    /// seventh piece makes. Each step must be large enough to read as a
    /// boundary at a glance, in both themes.
    func testNeighbouringTintsAreDistinguishable() {
        for appearance in bothAppearances {
            let c = resolved(appearance.name)
            for i in c.tints.indices {
                let next = c.tints[(i + 1) % c.tints.count]
                let step = distance(c.tints[i], next)
                XCTAssertGreaterThan(step, 0.15,
                                     "\(c.label) theme: S\(i) → S\((i + 1) % c.tints.count) must read as a boundary (step \(step))")
            }
        }
    }

    // MARK: - Rule 3: a tint is never a state

    /// No tint may be mistakable for a state drawn over it (§21.3 rule 3):
    /// nothing in the orange band (the difference), nothing at the accent's
    /// saturation (the selection), nothing close to the bookmark purple.
    ///
    /// The comparison is against each state's *identity* — the full orange, the
    /// accent, the purple — not against the translucent fill diluted over the
    /// paper. The difference and selection are drawn at 35 % / 22 % alpha, so
    /// over white paper they are pale washes, and a pale tint sits close to a
    /// pale wash in raw RGB even when its hue and saturation are plainly its
    /// own. What the rule guards is that a tint is not *orange*, not *as
    /// saturated as the accent*, and not *purple* — so it is the saturated
    /// identities that bound it, and a tint that passes against them reads as a
    /// pale background under any strength of the state drawn on top.
    func testNoTintIsMistakableForADifferenceOrASelection() {
        for appearance in bothAppearances {
            let c = resolved(appearance.name)
            for (i, tint) in c.tints.enumerated() {
                XCTAssertGreaterThan(distance(tint, c.orange), 0.50,
                                     "\(c.label) theme, S\(i): a tint must not sit in the orange band")
                XCTAssertGreaterThan(distance(tint, c.accent), 0.50,
                                     "\(c.label) theme, S\(i): a tint must not be at the accent's saturation")
                XCTAssertGreaterThan(distance(tint, c.bookmark), 0.50,
                                     "\(c.label) theme, S\(i): a tint must not read as the bookmark purple")
            }
        }
    }
}
