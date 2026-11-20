// swift-tools-version:6.0
import Foundation
import PackageDescription

// Sparkle is vendored as a framework rather than fetched through SwiftPM: the
// package manager needs a git clone, and this project is developed on machines
// where that clone is unreliable. Scripts/fetch_sparkle.sh populates the folder.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sparkleDirectory = "\(packageRoot)/Vendor/Sparkle"

let package = Package(
    name: "Sightline",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sightline", targets: ["Sightline"]),
        .executable(name: "sightline-cli", targets: ["sightline-cli"]),
    ],
    targets: [
        .target(
            name: "SightlineCore",
            path: "Sources/SightlineCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Sightline",
            dependencies: ["SightlineCore"],
            path: "Sources/Sightline",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // swiftc needs the framework search path to resolve `import Sparkle`.
                .unsafeFlags(["-F", sparkleDirectory]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", sparkleDirectory, "-framework", "Sparkle",
                    // Inside the .app the framework is copied to Contents/Frameworks;
                    // for a plain `swift run` it is loaded from Vendor/Sparkle.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", sparkleDirectory,
                ])
            ]
        ),
        .executableTarget(
            name: "sightline-cli",
            dependencies: ["SightlineCore"],
            path: "Sources/sightline-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SightlineCoreTests",
            dependencies: ["SightlineCore"],
            path: "Tests/SightlineCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
