// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Claudette",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Claudette", targets: ["Claudette"])
    ],
    targets: [
        .executableTarget(
            name: "Claudette",
            path: "Sources/Claudette"
        )
    ]
)
