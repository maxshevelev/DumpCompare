// swift-tools-version: 5.9
//
//  FITTool — the Intel Firmware Interface Table, read and repaired.
//
//  The table is not part of the UEFI tree: it is found through a pointer at a
//  fixed physical address, its entries address memory rather than the file, and
//  what they point at is often outside any FFS file. So its structure, its
//  rules and its edits live here, in a tool-module, and what it takes from
//  `UEFIFormat` is the one thing it cannot work out for itself — the mapping
//  between an address and an offset, which comes from a full parse of the image
//  (`Design/TOOL_MODULES_PLAN.md`, `Design/UEFI/FIT_TABLE_FORMAT.md`).
//
//  Two targets, as every tool-module has: the decisions, tested by `swift test`
//  over images built byte by byte, and the view over them.
//

import PackageDescription

let package = Package(
    name: "FITTool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FITToolUI", targets: ["FITToolUI"])
    ],
    dependencies: [
        .package(path: "../../ToolModuleKit"),
        .package(path: "../../UEFIFormat")
    ],
    targets: [
        .target(name: "FITTool", dependencies: [
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIFormat", package: "UEFIFormat")
        ]),
        .target(name: "FITToolUI", dependencies: [
            "FITTool",
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIFormat", package: "UEFIFormat")
        ]),
        .testTarget(name: "FITToolTests", dependencies: ["FITTool"])
    ]
)
