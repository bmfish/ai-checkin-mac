// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AICheckinMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AICheckinMac",
            path: "Sources/AICheckinMac"
        )
    ]
)
