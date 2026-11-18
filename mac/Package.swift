// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnboundHost",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "unbound-host", targets: ["unbound-host"]),
        .executable(name: "Unbound", targets: ["UnboundApp"]),
        .library(name: "UnboundHostCore", targets: ["UnboundHostCore"]),
    ],
    targets: [
        // Objective-C shim around the undocumented CGVirtualDisplay family.
        // Every private symbol is resolved at runtime (NSClassFromString) so a
        // missing/renamed API degrades to "unsupported" instead of a dyld crash.
        .target(
            name: "CGVirtualDisplayBridge",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        // IOUSBHost wrapper for Android Open Accessory (USB-C without developer mode).
        .target(
            name: "UnboundUSB",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit"), .linkedFramework("Foundation")]
        ),
        .target(
            name: "UnboundHostCore",
            dependencies: ["CGVirtualDisplayBridge", "UnboundUSB"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(name: "unbound-host", dependencies: ["UnboundHostCore"]),
        // Menu-bar app (what users install). Bundled into Unbound.app by scripts/package.sh.
        .executableTarget(name: "UnboundApp", dependencies: ["UnboundHostCore"],
                          linkerSettings: [.linkedFramework("ServiceManagement")]),
        .testTarget(name: "UnboundHostCoreTests", dependencies: ["UnboundHostCore"]),
    ]
)
