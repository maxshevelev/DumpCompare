// swift-tools-version: 5.9
//
//  FreshData — a value fetched once, then re-checked once a day.
//
//  A package of its own because all three of the app's live sources want the
//  same thing and none of them may depend on another: `MEATool`'s MEA.dat and
//  Huffman.dat, `UEFITool`'s guids.csv, `FITTool`'s microcode catalogue. Each
//  is a parsed value that costs a download and a parse, changes about weekly,
//  and is wanted again the moment the tool is opened on a second file. Three
//  copies of "hold it, and check it now and then" would be three chances to
//  get the failure states wrong, and the failure states are the whole point.
//
//  It knows nothing about HTTP: the caller hands it a closure that turns the
//  stored validator into an outcome. So the package links nothing, and its
//  tests need neither a network nor the wall clock.
//

import PackageDescription

let package = Package(
    name: "FreshData",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FreshData", targets: ["FreshData"])
    ],
    targets: [
        .target(name: "FreshData"),
        .testTarget(name: "FreshDataTests", dependencies: ["FreshData"])
    ]
)
