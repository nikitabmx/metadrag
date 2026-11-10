// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetaDrag",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MetaDrag",
            path: "Sources/MetaDrag",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
