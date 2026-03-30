// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcp-calendar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "mcp-calendar",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources",
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Resources/Info.plist",
                ]),
            ]
        ),
    ]
)
