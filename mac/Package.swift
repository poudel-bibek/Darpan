// swift-tools-version:5.9
// Darpan for Mac — native client for the Darpan remote desktop (PROTOCOL.md).
// Apple frameworks, plus libtailscale (BSD-3) for the built-in tailnet connection.
// Build everything with `bash build.sh`; `swift build` needs `bash tailscale/build-libtailscale.sh` first.
import PackageDescription

let libtailscale = Context.packageDirectory + "/.build/libtailscale"

let package = Package(
    name: "Darpan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Darpan", targets: ["Darpan"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
    ],
    targets: [
        // Protocol, auth, H.264 plumbing, key map: no UI, exercised by SelfTest.
        .target(name: "DarpanCore", path: "Sources/DarpanCore"),
        // tsnet as a C library, built by tailscale/build-libtailscale.sh.
        .systemLibrary(name: "CTailscale", path: "Sources/CTailscale"),
        .executableTarget(
            name: "Darpan", dependencies: ["DarpanCore", "CTailscale"], path: "Sources/Darpan",
            linkerSettings: [
                .unsafeFlags(["-L", libtailscale]),
                .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"), .linkedFramework("IOKit"),
                .linkedLibrary("resolv"),
            ]),
        .executableTarget(name: "SelfTest", dependencies: ["DarpanCore"], path: "Sources/SelfTest"),
        // A stand-in for the Linux host on this Mac, for testing the app end to end.
        .executableTarget(name: "FakeHost", dependencies: ["DarpanCore"], path: "tools/FakeHost"),
    ]
)
