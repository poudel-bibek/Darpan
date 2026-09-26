// swift-tools-version:5.9
// Darpan for Mac — native client for the Darpan remote desktop (PROTOCOL.md).
// Apple frameworks only. Build everything with `bash build.sh`.
import PackageDescription

let package = Package(
    name: "Darpan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Darpan", targets: ["Darpan"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
    ],
    targets: [
        // Protocol, auth, H.264 plumbing, key map: no UI, exercised by SelfTest.
        .target(name: "DarpanCore", path: "Sources/DarpanCore"),
        .executableTarget(name: "Darpan", dependencies: ["DarpanCore"], path: "Sources/Darpan"),
        .executableTarget(name: "SelfTest", dependencies: ["DarpanCore"], path: "Sources/SelfTest"),
        // A stand-in for the Linux host on this Mac, for testing the app end to end.
        .executableTarget(name: "FakeHost", dependencies: ["DarpanCore"], path: "tools/FakeHost"),
    ]
)
