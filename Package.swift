// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Coincide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CoincideCore", targets: ["CoincideCore"]),
               .executable(name: "Coincide", targets: ["Coincide"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CoincideCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Coincide", dependencies: ["CoincideCore"]),
        .testTarget(name: "CoincideCoreTests", dependencies: ["CoincideCore"], resources: [.copy("Fixtures")])
    ]
)
