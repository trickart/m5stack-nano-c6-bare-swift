// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "esp32-c6-bare-swift",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "Application", targets: ["Application"]),
        .executable(name: "Bootloader", targets: ["Bootloader"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-mmio.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "HeapAllocator",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .target(
            name: "MemoryPrimitives",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .unsafeFlags(["-Xllvm", "-disable-loop-idiom-memcpy"]),
            ]
        ),
        .target(
            name: "SoftFloat",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .target(
            name: "SoftInt",
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
            ]
        ),
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
                "MemoryPrimitives",
                "HeapAllocator",
                "SoftFloat",
                "SoftInt",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .enableExperimentalFeature("Volatile"),
            ]
        ),
        .executableTarget(
            name: "Bootloader",
            dependencies: [
                "MemoryPrimitives",
                "HeapAllocator",
                "SoftFloat",
            ],
            swiftSettings: [
                .enableExperimentalFeature("Embedded"),
                .enableExperimentalFeature("Extern"),
                .enableExperimentalFeature("Volatile"),
            ]
        ),
    ]
)
