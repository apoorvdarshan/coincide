// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Coincide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CoincideCore", targets: ["CoincideCore"]),
               .executable(name: "Coincide", targets: ["Coincide"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1", traits: [])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CoincideCore", dependencies: ["CSQLite"]),
        .target(name: "CoincideTerminal", dependencies: ["CoincideCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(name: "Coincide", dependencies: ["CoincideCore", "CoincideTerminal"]),
        .testTarget(name: "CoincideCoreTests", dependencies: ["CoincideCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoincideTerminalTests", dependencies: ["CoincideTerminal"])
    ]
)
