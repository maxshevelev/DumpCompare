// swift-tools-version: 5.9
//
//  UEFIContentSource — the host's open file, seen as bytes a parser can read.
//
//  Ten lines that belong to neither side of the seam. `ToolModuleKit` is what a
//  tool-module and the app agree on and must not drag a firmware parser behind
//  it, and `UEFIImage`'s whole claim is that it depends on nothing — so the
//  introduction between `ToolContentReader` and `ByteSource` cannot live in
//  either. It lived as one copy inside the FIT tool-module while it had one
//  user; the structure browser is the second, and `Design/TOOL_MODULES_PLAN.md`
//  says what happens then: shared code between tool-modules moves to a shared
//  package.
//

import PackageDescription

let package = Package(
    name: "UEFIContentSource",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UEFIContentSource", targets: ["UEFIContentSource"])
    ],
    dependencies: [
        .package(path: "../ToolModuleKit"),
        .package(path: "../UEFIImage")
    ],
    targets: [
        .target(name: "UEFIContentSource", dependencies: [
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage")
        ]),
        .testTarget(
            name: "UEFIContentSourceTests",
            dependencies: ["UEFIContentSource"]
        )
    ]
)
