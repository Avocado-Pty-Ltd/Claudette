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
            path: "Sources/Claudette",
            resources: [
                // The browser-use sidecar ships verbatim inside the app bundle
                // and is run by whichever Python has browser-use installed.
                // `.copy` keeps the directory structure so Bundle.module finds
                // it at browser_agent/runner.py.
                .copy("Resources/browser_agent")
            ]
        )
    ]
)
