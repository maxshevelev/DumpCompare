import XCTest
import AppKit
@testable import DumpCompare

/// § App icon: the artwork must actually reach the built bundle. An asset
/// catalog with an empty `AppIcon.appiconset` compiles without a word of
/// complaint and leaves the app wearing the generic placeholder, so the checks
/// look at the pixels the build produced.
///
/// They read the catalog's image (`NSImage(named:)`), not
/// `NSApp.applicationIconImage`, which the system may serve from its own icon
/// cache. Note that removing the artwork does not fail these on an incremental
/// build: `Assets.car` is copied back from the build intermediates and the
/// bundle keeps the previous icon. Only a clean build shows the difference —
/// which is exactly the build that ships. `AppIcon.icns`, also in the bundle,
/// stops at 256; the large images live only in the compiled catalog.
final class AppIconTests: XCTestCase {

    private func builtIcon() throws -> NSImage {
        try XCTUnwrap(NSImage(named: "AppIcon"),
                      "the build compiles the icon asset into the bundle")
    }

    func testTheBundleIsBuiltWithTheIconAsset() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
                       "AppIcon",
                       "the app target names AppIcon as its icon asset")
    }

    func testTheIconShowsTheChipAndItsDifferenceCell() throws {
        let icon = try builtIcon()
        let side = 256
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: side, pixelsHigh: side,
                                                bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // The difference cell: the app's orange, which nothing else in the icon
        // comes close to, and which the placeholder icon has none of.
        var orange = 0
        var opaque = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if colour.alphaComponent > 0.5 { opaque += 1 }
                if colour.redComponent > 0.75, colour.blueComponent < 0.35,
                   colour.greenComponent > 0.4, colour.greenComponent < 0.8 {
                    orange += 1
                }
            }
        }
        XCTAssertGreaterThan(opaque, 3000, "the chip covers the tile, not an empty image")
        XCTAssertGreaterThan(orange, 150,
                             "the marked byte's orange cell is part of the artwork")

        // The package is free-standing: no plate behind it (§2). Probing empty
        // corners would not say that — the chip now fills nearly the whole tile,
        // and the plate this replaced left its corners clear too. What says it is
        // the row through the leads: five separate runs of artwork with the
        // background showing between them. Any ground behind the chip fills those
        // gaps, and the widest row of the tile becomes a single run.
        var mostRuns = 0
        for y in 0..<rep.pixelsHigh {
            var runs = 0
            var inRun = false
            for x in 0..<rep.pixelsWide {
                let isOpaque = (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                if isOpaque, !inRun { runs += 1 }
                inRun = isOpaque
            }
            mostRuns = max(mostRuns, runs)
        }
        XCTAssertGreaterThanOrEqual(mostRuns, 5,
                                    "the leads stand clear of one another: the chip is "
                                    + "drawn on nothing, not on a plate")
    }

    func testTheIconIsSuppliedUpToTheLargestSize() throws {
        let widest = try builtIcon().representations.map(\.pixelsWide).max() ?? 0
        XCTAssertGreaterThanOrEqual(widest, 1024,
                                    "the catalog carries the 512@2x image, so the Finder "
                                    + "and Dock never upscale a smaller one")
    }
}
