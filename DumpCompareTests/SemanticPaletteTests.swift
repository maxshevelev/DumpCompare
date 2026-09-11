import AppKit
import AppPalette
import XCTest
@testable import DumpCompare

/// The palette has two halves — the asset catalogue a colour is edited in, and
/// the numbers a build without a compiled catalogue falls back to — and this is
/// where they are held to each other.
///
/// It has to be here rather than in the package: `swift build` copies an
/// `.xcassets` verbatim instead of compiling it, so the package's own tests
/// never see a catalogue at all. The app is built by Xcode, which compiles it
/// into the bundle that ships, and this suite runs against that.
@MainActor
final class SemanticPaletteTests: XCTestCase {
    /// The app reads the catalogue. If this fails the app is quietly living on
    /// the fallback numbers, which is almost right and therefore the worst kind
    /// of wrong: the resource did not build, or a name was changed in the
    /// editor and not in the code.
    func testTheAppReadsTheCatalogue() {
        XCTAssertTrue(SemanticColors.isFromCatalogue,
                      "Colors.xcassets did not reach the app bundle")
    }

    /// And it says the same as the read-back, in both themes.
    ///
    /// This pins no colour: both sides are the same choice, and picking a new
    /// one moves them together — a shade edited in Xcode and regenerated passes
    /// here whatever it is. What it catches is the two coming apart: a colour
    /// picked and not regenerated, and the bug that arrived with the first
    /// colour ever picked here — Xcode's picker writes Display P3, so the same
    /// three numbers read as sRGB are a different colour in every build that
    /// has no compiled catalogue.
    func testTheCatalogueAndTheReadBackAgree() throws {
        for definition in SemanticColors.everySet {
            let entry = try XCTUnwrap(definition.catalogued,
                                      "\(definition.name) is not in the catalogue")
            for dark in [false, true] {
                let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
                var shown: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    shown = entry.usingColorSpace(.sRGB)
                }
                let drawn = try XCTUnwrap(shown)
                let wanted = definition.shade(dark: dark)
                let theme = dark ? "dark" : "light"
                XCTAssertEqual(drawn.redComponent, wanted.redComponent, accuracy: 0.01,
                               "\(definition.name) red, \(theme)")
                XCTAssertEqual(drawn.greenComponent, wanted.greenComponent, accuracy: 0.01,
                               "\(definition.name) green, \(theme)")
                XCTAssertEqual(drawn.blueComponent, wanted.blueComponent, accuracy: 0.01,
                               "\(definition.name) blue, \(theme)")
                XCTAssertEqual(drawn.alphaComponent, wanted.alphaComponent, accuracy: 0.01,
                               "\(definition.name) alpha, \(theme)")
            }
        }
    }

    /// The palette is what the app draws meanings with: no semantic colour is
    /// picked by hand in the app's own sources any more. A `systemRed` in a
    /// view is a colour chosen where a meaning should have been.
    ///
    /// Read off the sources rather than off the screen, because what this
    /// guards is a habit rather than a pixel — and the habit is what drifted.
    func testTheAppDoesNotPickSemanticColoursByHand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // DumpCompareTests
            .deletingLastPathComponent()          // the repository
        // The dump's own grid is the documented exception: its orange and red
        // are fills in the comparison model's vocabulary, not the state of a
        // value, and they are built from system colours on purpose.
        let exempt = ["HexView.swift"]
        var sources: [URL] = []
        for folder in ["Modules", "DumpCompareApp"] {
            let walk = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            sources += (walk?.compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") }
                .filter { !exempt.contains($0.lastPathComponent) }
        }

        var offenders: [String] = []
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard text.contains(".systemRed") || text.contains(".systemGreen") else { continue }
            offenders.append(file.lastPathComponent)
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a semantic colour is picked by hand rather than named: \(offenders)")
    }
}
