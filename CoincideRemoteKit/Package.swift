// swift-tools-version: 6.2
// What Coincide on the Mac and Coincide Remote on iPhone and iPad share: the remote protocol, pairing, the pinned TLS
// WebSocket the phone connects with, and the theme palettes. Foundation, CryptoKit and Network only, so it builds for
// both platforms.
import PackageDescription

let package = Package(
    name: "CoincideRemoteKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "CoincideRemoteKit", targets: ["CoincideRemoteKit"])
    ],
    targets: [
        .target(name: "CoincideRemoteKit")
    ]
)
