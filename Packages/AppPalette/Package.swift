// swift-tools-version: 5.9
//
//  AppPalette — the app's colours, in one place, as a catalogue.
//
//  A package of its own rather than a file in `ToolModuleKit`, which is the
//  seam between a tool-module and the app: what a colour *means* is the whole
//  app's business — the panels, the forms, the sheets — and a palette that
//  lives in the tool-module seam is one that half the app has no business
//  importing. Everything that draws links this; it links nothing.
//
//  The values are an asset catalogue rather than numbers in Swift, so they are
//  edited in Xcode's colour editor with both appearances side by side, and the
//  code names a meaning rather than a colour.
//

import PackageDescription

let package = Package(
    name: "AppPalette",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AppPalette", targets: ["AppPalette"])
    ],
    targets: [
        .target(name: "AppPalette", resources: [.process("Resources")]),
        .testTarget(name: "AppPaletteTests", dependencies: ["AppPalette"])
    ]
)
