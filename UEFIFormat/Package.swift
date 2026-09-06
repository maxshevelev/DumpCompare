// swift-tools-version: 5.9
//
//  UEFIFormat — the domain model of a UEFI firmware image.
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

import PackageDescription

let package = Package(
    name: "UEFIFormat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UEFIFormat", targets: ["UEFIFormat"])
    ],
    targets: [
        .target(name: "UEFIFormat"),
        .testTarget(
            name: "UEFIFormatTests",
            dependencies: ["UEFIFormat"]
        )
    ]
)
