// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CueVideo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CueVideo", targets: ["CueVideo"]),
        // The MCP server Claude uses to control CueVideo (ships inside CueVideo.app).
        .executable(name: "cuevideo-mcp", targets: ["CueVideoMCP"]),
        // The ATEM and PTZ engine, shared with CueScreens and CueStack.
        .library(name: "CueATEM", targets: ["CueATEM"]),
    ],
    dependencies: [
        // Shared Cue family code: design tokens and the NDI bridge.
        .package(url: "https://github.com/Churchfront/CueKit.git", from: "0.2.0"),
    ],
    targets: [
        .target(name: "CueATEM", path: "Sources/CueATEM"),
        .executableTarget(name: "CueVideoMCP", path: "Sources/CueVideoMCP"),
        .executableTarget(
            name: "CueVideo",
            dependencies: [
                "CueATEM",
                .product(name: "CueDesign", package: "CueKit"),
                .product(name: "CueNDI", package: "CueKit"),
            ],
            path: "Sources/CueVideo"
        ),
    ]
)
