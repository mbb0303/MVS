// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MVS",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MVS", targets: ["MVS"])
    ],
    targets: [
        .executableTarget(
            name: "MVS",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "MVSTests",
            dependencies: ["MVS"]
        )
    ]
)
