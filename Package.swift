// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "esp32-c6-bare-swift",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "Application", targets: ["Application"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-mmio.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Registers",
            dependencies: [
                .product(name: "MMIO", package: "swift-mmio"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
            ]
        ),
        .executableTarget(
            name: "Application",
            dependencies: [
                "Registers",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .enableExperimentalFeature("Volatile"),
            ]
        ),
    ]
)
