// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)

let cssh = Target.systemLibrary(name: "CSSH", path: "Sources/CSSHLinux", pkgConfig: "cssh")
#else

let cssh = Target.binaryTarget(name: "CSSH", path: "Frameworks/CSSH.xcframework")
#endif

let package = Package(
    name: "MacSCP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
    ],
    targets: [
        cssh,
        .target(name: "RemoteCore", dependencies: ["CSSH"]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),

        .executableTarget(name: "sftp-bench", dependencies: ["CSSH"]),
    ]
)
