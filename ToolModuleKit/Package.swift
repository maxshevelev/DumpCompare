// swift-tools-version: 5.9
//
//  ToolModuleKit — the whole of what a tool-module and the app agree on.
//
//  Both sides import this and nothing else of each other's: a tool-module never
//  sees `DumpCompareApp` or `DumpCompareCore`, and the app never sees a
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
    targets: [
        .target(name: "ToolModuleKit"),
        .testTarget(
            name: "ToolModuleKitTests",
            dependencies: ["ToolModuleKit"]
        )
    ]
)
