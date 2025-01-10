// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "background_downloader",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "background-downloader", targets: ["background_downloader"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "background_downloader",
            dependencies: [],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)