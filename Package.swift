// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenSleep",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ScreenSleep",
            path: "Sources/ScreenSleep"
        )
    ]
)
