// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AccessTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Headless VT100/xterm engine. We use its Terminal + LocalProcess, not its view.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "AccessTerm",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/AccessTerm"
        )
    ]
)
