// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Securely",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Securely", path: "Sources/Securely"),
        .executableTarget(name: "securely-mcp", path: "Sources/securely-mcp"),
    ]
)
