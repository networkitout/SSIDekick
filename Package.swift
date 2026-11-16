// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiFiUtil",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "WiFiUtil", targets: ["WiFiUtil"]),
    ],
    targets: [
        .target(name: "WiFiCore"),
        .target(
            name: "WiFiSystem",
            dependencies: ["WiFiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WiFiUtil",
            dependencies: ["WiFiCore", "WiFiSystem"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "WiFiCoreTests", dependencies: ["WiFiCore"]),
        .testTarget(
            name: "WiFiSystemTests",
            dependencies: ["WiFiSystem", "WiFiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
