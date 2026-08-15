// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "satori",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SatoriCore", targets: ["SatoriCore"]),
        .executable(name: "satori", targets: ["SatoriApp"]),
        .executable(name: "satori-core-tests", targets: ["SatoriCoreTests"])
    ],
    targets: [
        .target(name: "SatoriCore"),
        .executableTarget(
            name: "SatoriApp",
            dependencies: ["SatoriCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "SatoriCoreTests",
            dependencies: ["SatoriCore"],
            path: "tests/SatoriCoreTests"
        )
    ]
)
