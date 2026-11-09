// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardDeck",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .executable(name: "ClipboardDeck", targets: ["ClipboardDeck"]),
    ],
    targets: [
        .target(name: "ClipboardCore"),
        .target(
            name: "ClipboardNativeBridge",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-fobjc-arc-exceptions"])],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "ClipboardDeck", dependencies: ["ClipboardCore", "ClipboardNativeBridge"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
    ]
)
