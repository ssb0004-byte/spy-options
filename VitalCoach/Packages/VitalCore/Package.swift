// swift-tools-version: 6.0
// VitalCore: platform-independent domain logic for VitalCoach.
// No UIKit/SwiftUI/HealthKit imports are allowed here so that the
// package compiles and tests on macOS, iOS and Linux CI alike.
import PackageDescription

let package = Package(
    name: "VitalCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "VitalCore", targets: ["VitalCore"]),
    ],
    targets: [
        .target(name: "VitalCore"),
        .testTarget(name: "VitalCoreTests", dependencies: ["VitalCore"]),
    ],
    swiftLanguageModes: [.v6]
)
