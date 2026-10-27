// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Muse",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Muse",
            path: "Sources/Muse",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
