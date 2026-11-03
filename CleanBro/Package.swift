// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanBro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CleanBro",
            path: "Sources/CleanBro"
        )
    ],
    swiftLanguageModes: [.v5]
)
