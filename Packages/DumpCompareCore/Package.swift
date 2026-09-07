// swift-tools-version: 5.9
//
//  DumpCompareCore — pure Swift storage + model layers.
//  Must never import AppKit. UI lives in the app target.
//

import PackageDescription

let package = Package(
    name: "DumpCompareCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DumpCompareCore", targets: ["DumpCompareCore"])
    ],
    targets: [
        .target(name: "DumpCompareCore"),
        .testTarget(
            name: "DumpCompareCoreTests",
            dependencies: ["DumpCompareCore"]
        )
    ]
)
