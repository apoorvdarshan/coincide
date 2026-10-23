// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Coincide",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CoincideCore", targets: ["CoincideCore"]),
               .executable(name: "Coincide", targets: ["Coincide"]),
               .executable(name: "CoincideScriptHelper", targets: ["CoincideScriptHelper"]),
               .executable(name: "CoincideEnvironment", targets: ["CoincideEnvironment"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1", traits: []),
                   .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
                   .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "CoincideCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CoincideScriptHelper", dependencies: ["CoincideCore"]),
        .executableTarget(name: "CoincideEnvironment", dependencies: ["CoincideCore", "CoincideTerminal"]),
        .target(name: "CoincideTerminal", dependencies: ["CoincideCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "CoincideMarkdown", dependencies: [.product(name: "Markdown", package: "swift-markdown"), .product(name: "SwiftMath", package: "SwiftMath")]),
        .executableTarget(name: "Coincide", dependencies: ["CoincideCore", "CoincideTerminal", "CoincideMarkdown"]),
        .testTarget(name: "CoincideCoreTests", dependencies: ["CoincideCore", "CSQLite", "CoincideScriptHelper", "CoincideEnvironment"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoincideTerminalTests", dependencies: ["CoincideTerminal", "CoincideCore"]),
        .testTarget(name: "CoincideMarkdownTests", dependencies: ["CoincideMarkdown"]),
        .testTarget(name: "CoincideUITests", dependencies: ["Coincide", "CoincideCore"])
    ]
)
