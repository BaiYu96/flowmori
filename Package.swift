// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flowmori",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Flowmori", targets: ["Flowmori"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "FlowmoriCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Flowmori", dependencies: ["FlowmoriCore"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ScreenCaptureKit"),
                             .linkedFramework("ServiceManagement"), .linkedFramework("ApplicationServices")]),
        .testTarget(name: "FlowmoriCoreTests", dependencies: ["FlowmoriCore"]),
        .testTarget(name: "FlowmoriPlatformTests", dependencies: ["Flowmori", "FlowmoriCore"])
    ],
    swiftLanguageModes: [.v5]
)
