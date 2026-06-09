// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

var swiftSettings: [SwiftSetting] = []
if ProcessInfo.processInfo.environment["BYPASS_PERMISSION_NOTIFICATIONS"] == "1" {
    swiftSettings.append(.define("BYPASS_PERMISSION_NOTIFICATIONS"))
}
if ProcessInfo.processInfo.environment["BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY"] == "1" {
    swiftSettings.append(.define("BYPASS_PERMISSION_IOSADDTOPHOTOLIBRARY"))
}
if ProcessInfo.processInfo.environment["BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY"] == "1" {
    swiftSettings.append(.define("BYPASS_PERMISSION_IOSCHANGEPHOTOLIBRARY"))
}

let package = Package(
    name: "background_downloader",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "background-downloader", targets: ["background_downloader"])
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "background_downloader",
            dependencies: [
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: swiftSettings.isEmpty ? nil : swiftSettings
        )
    ]
)