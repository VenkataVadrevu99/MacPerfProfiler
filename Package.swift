// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacPerfProfiler",
    platforms: [.macOS(.v13)],
    targets: [
        // C++ sampling core — uses Mach/IOKit APIs directly
        .target(
            name: "CSampler",
            path: "Sources/CSampler",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedLibrary("proc")
            ]
        ),
        // Swift CLI executable
        .executableTarget(
            name: "MacPerfProfiler",
            dependencies: ["CSampler"],
            path: "Sources/MacPerfProfiler"
        ),
        .testTarget(
            name: "MacPerfProfilerTests",
            dependencies: ["CSampler"],
            path: "Tests/MacPerfProfilerTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
