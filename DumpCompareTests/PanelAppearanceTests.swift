import AppKit
import DumpCompareCore
import XCTest
@testable import DumpCompare

/// The find bar and the search-results panel paint their backgrounds onto a
/// CALayer. A dynamic `NSColor.controlBackgroundColor` assigned in `setUp` —
/// before the view is in a window — is captured once, so a launch in one theme
/// left the panel stuck in it: switching to dark mode kept the bar white.
/// `viewDidChangeEffectiveAppearance` re-resolves the color against the current
/// appearance, and these tests pin that the layer actually follows the
/// appearance instead of holding the launch-theme bake (§3.1).
@MainActor
final class PanelAppearanceTests: XCTestCase {
    /// The layer's first background component (red, or the gray value for a
    /// gray color) — `controlBackgroundColor` is a gray, so its component cleanly
    /// separates the light plate (> 0.8) from the dark plate (< 0.25).
    private func backgroundComponent(_ c: CGColor?) -> CGFloat {
        guard let c, c.numberOfComponents >= 1 else { return -1 }
        return c.components?[0] ?? -1
    }

    func testFindBarBackgroundFollowsAppearance() {
        let bar = FindBarView()
        defer { bar.removeFromSuperview() }

        bar.appearance = NSAppearance(named: .darkAqua)
        bar.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(bar.layer?.backgroundColor), 0.5,
                          "the bar must use the dark plate in dark mode, not the light-launch bake")

        bar.appearance = NSAppearance(named: .aqua)
        bar.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(bar.layer?.backgroundColor), 0.5,
                            "the bar must return to the light plate in light mode")
    }

    func testSearchResultsBackgroundFollowsAppearance() {
        let results = SearchResultsView()
        defer { results.removeFromSuperview() }

        results.appearance = NSAppearance(named: .darkAqua)
        results.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(results.layer?.backgroundColor), 0.5,
                          "the results panel must use the dark plate in dark mode")

        results.appearance = NSAppearance(named: .aqua)
        results.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(results.layer?.backgroundColor), 0.5,
                            "the results panel must return to the light plate in light mode")
    }

    /// The minimap paints its paper onto a layer the same way, from
    /// `textBackgroundColor` — white in light, near-black in dark — so it needs
    /// the same re-resolve or the panel keeps the launch theme's paper.
    func testMinimapBackgroundFollowsAppearance() {
        let minimap = MinimapView(frame: NSRect(x: 0, y: 0, width: 120, height: 400))
        defer { minimap.removeFromSuperview() }

        minimap.appearance = NSAppearance(named: .darkAqua)
        minimap.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(backgroundComponent(minimap.layer?.backgroundColor), 0.5,
                          "the minimap must use the dark paper in dark mode")

        minimap.appearance = NSAppearance(named: .aqua)
        minimap.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(backgroundComponent(minimap.layer?.backgroundColor), 0.5,
                            "the minimap must return to the light paper in light mode")
    }
}
