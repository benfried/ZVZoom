// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZVZoom",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ZVZoom",
            path: "Sources/ZVZoom",
            linkerSettings: [
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
