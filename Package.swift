// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Vopause",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Vopause", targets: ["Vopause"]),
        .executable(name: "VopauseCoreSmokeTests", targets: ["VopauseCoreSmokeTests"])
    ],
    targets: [
        .target(
            name: "VopauseCore",
            path: "Sources/VopauseCore"
        ),
        .executableTarget(
            name: "Vopause",
            dependencies: ["VopauseCore"],
            path: "Sources/Vopause"
        ),
        .executableTarget(
            name: "VopauseCoreSmokeTests",
            dependencies: ["VopauseCore"],
            path: "Tools/VopauseCoreSmokeTests"
        )
    ]
)
