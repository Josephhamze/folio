// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Folio"),
        .testTarget(name: "FolioTests", dependencies: ["Folio"]),
    ]
)
