// swift-tools-version: 5.9
//
//  ToolModuleKit — the whole of what a tool-module and the app agree on.
//
//  Both sides import this and nothing else of each other's: a tool-module never
//  sees `ByteRipperApp` or `ByteRipperCore`, and the app never sees a
//  tool-module's tree, its parse or its diagnostics. `Design/TOOL_MODULES_PLAN.md`
//  says why — making the app's core a public API is a price with no return.
//

import PackageDescription

let package = Package(
    name: "ToolModuleKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ToolModuleKit", targets: ["ToolModuleKit"])
    ],
    // The app's colours. This draws — the tables here put a marker beside a
    // value — and a marker's colour is a meaning, so it comes from the palette
    // rather than from a system colour picked by hand.
    dependencies: [
        .package(path: "../AppPalette")
    ],
    targets: [
        .target(name: "ToolModuleKit",
                dependencies: [.product(name: "AppPalette", package: "AppPalette")]),
        .testTarget(
            name: "ToolModuleKitTests",
            dependencies: ["ToolModuleKit"]
        )
    ]
)
