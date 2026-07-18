// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ProjectsBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ProjectsBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
