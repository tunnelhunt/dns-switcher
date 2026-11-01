// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DNSSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DNSSwitcher", targets: ["DNSSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "DNSSwitcher",
            path: "Sources/DNSSwitcher"
        )
    ]
)
