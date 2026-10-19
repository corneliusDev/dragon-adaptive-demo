// swift-tools-version: 5.9
//  DragonEngine — the device-agnostic adaptive HUD engine.
//  Foundation only: no UIKit, SwiftUI, ActiveLookSDK, CoreLocation, CoreMotion
//  or HealthKit. Nothing in here reads the clock; callers pass run time in.

import PackageDescription

let package = Package(
    name: "DragonEngine",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DragonEngine", targets: ["DragonEngine"]),
    ],
    targets: [
        .target(name: "DragonEngine"),
        .testTarget(name: "DragonEngineTests", dependencies: ["DragonEngine"]),
    ]
)
