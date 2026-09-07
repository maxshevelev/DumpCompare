// swift-tools-version: 5.9
//
//  UEFIImage — the domain model of a UEFI firmware image.
//
//  A shared package, not a tool-module: the structure browser and the FIT
//  editor both need the same tree, and parsing an image twice in two packages
//  is how the two would drift apart. It depends on nothing — not on
//  `ToolModuleKit`, not on the app — because a parser that can be run by
//  `swift test` over a hand-built image is a parser whose diagnostics can be
//  pinned down without a window.
//
//  `Design/UEFI/UEFI_IMAGE_FORMAT.md` is the specification this follows, and
//  its section numbers are quoted throughout.
//
//  The module is named after the struct it exports, which is what the parse
//  produces. That costs one thing, measured: a type shadows a module of the
//  same name, so `UEFIImage.UEFINode` does not resolve — module-qualified
//  names into this module are not available. Nothing used them.
//

import PackageDescription

let package = Package(
    name: "UEFIImage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UEFIImage", targets: ["UEFIImage"])
    ],
    targets: [
        .target(name: "UEFIImage"),
        .testTarget(
            name: "UEFIImageTests",
            dependencies: ["UEFIImage"]
        )
    ]
)
