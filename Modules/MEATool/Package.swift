// swift-tools-version: 5.9
//
//  MEATool — the "ME Analyzer" instrument panel: two tabs, Summary and Full
//  Tree, a view over `MEFirmware`'s `FirmwareAnalysis`.
//
//  The engine (`MEFirmwareAnalyzer.analyze`) returns one big typed model; this
//  module turns it into the curated tree the tool shows — hand-named groups in a
//  fixed order, rows carrying the byte ranges the panel reveals, details read
//  from the very model rows stand for. The tree building is a pure target,
//  tested by `swift test` over in-memory `FirmwareAnalysis` fixtures; the UI
//  target only lays out what it returns.
//
//  Two targets, as every tool-module has: the decisions and the view over them.
//

import PackageDescription

let package = Package(
    name: "MEATool",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MEATool", targets: ["MEATool"]),
        .library(name: "MEAToolUI", targets: ["MEAToolUI"])
    ],
    dependencies: [
        .package(path: "../../Packages/ALSplitView"),
        .package(path: "../../Packages/ToolModuleKit"),
        .package(path: "../../Packages/AppPalette"),
        .package(path: "../../Packages/MEFirmware"),
        .package(path: "../../Packages/UEFIImage")
    ],
    targets: [
        .target(name: "MEATool", dependencies: [
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
        ]),
        .target(name: "MEAToolUI", dependencies: [
            .product(name: "AppPalette", package: "AppPalette"),
            "MEATool",
            .product(name: "MEFirmware", package: "MEFirmware"),
            .product(name: "ALSplitView", package: "ALSplitView"),
            .product(name: "ToolModuleKit", package: "ToolModuleKit"),
            .product(name: "UEFIImage", package: "UEFIImage")
        ]),
        .testTarget(name: "MEAToolTests", dependencies: [
            "MEATool",
            .product(name: "MEFirmware", package: "MEFirmware")
        ])
    ]
)
