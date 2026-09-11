// swift-tools-version: 5.9
//
//  ByteRipperCore — pure Swift storage + model layers.
//  Must never import AppKit. UI lives in the app target.
//

import PackageDescription

let package = Package(
    name: "ByteRipperCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ByteRipperCore", targets: ["ByteRipperCore"])
    ],
    targets: [
        .target(name: "ByteRipperCore"),
        .testTarget(
            name: "ByteRipperCoreTests",
            dependencies: ["ByteRipperCore"]
        )
    ]
)
