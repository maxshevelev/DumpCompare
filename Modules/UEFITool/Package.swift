// swift-tools-version: 5.9
//
//  UEFITool — the structure of a UEFI firmware image, read and shown.
//
//  The "structure browser" `Design/TOOL_MODULES_PLAN.md` named but did not
//  build. It stands on the same seam as the FIT tool-module and reads the same
//  shared parser: what it adds is a tree, a zone for the one node in focus, and
//  a detail that says what that node is. `Design/UEFI_STRUCTURE_TOOL.md`.
//
//  Two targets, as every tool-module has: the decisions, tested by `swift test`
//  over images built byte by byte, and the view over them.
//

import PackageDescription

let package = Package(
    name: "UEFITool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UEFITool", targets: ["UEFITool"]),
        .library(name: "UEFIToolUI", targets: ["UEFIToolUI"])
    ],
    dependencies: [
        .package(path: "../../Packages/ALSplitView"),
        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/UEFIImage"),
        .package(path: "../../Packages/UEFIContentSource")
    ],
    targets: [
        .target(name: "UEFITool", dependencies: [
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage")
        ]),
        .target(name: "UEFIToolUI", dependencies: [
            "UEFITool",
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage"),
            .product(name: "UEFIContentSource", package: "UEFIContentSource")
        ]),
        .testTarget(name: "UEFIToolTests", dependencies: ["UEFITool"])
    ]
)
