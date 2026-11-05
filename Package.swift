// swift-tools-version: 6.1
import PackageDescription

let coreOnly = Context.environment["BAHA_CORE_ONLY"] == "1"
let skipDisabled = Context.environment["SKIP_ZERO"] == "1"
let skipEnabled = !coreOnly && !skipDisabled

let package = Package(
    name: "baha-plus",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BahaCore", targets: ["BahaCore"])
    ],
    dependencies: coreOnly ? [] : [
        .package(url: "https://github.com/skiptools/skip.git", from: "1.9.7"),
        .package(url: "https://github.com/skiptools/skip-ui.git", from: "1.54.0"),
        // WebView 124 can supply a null request-header map during navigation.
        // This upstream fix is newer than the latest tagged release (0.12.0).
        .package(url: "https://github.com/skiptools/skip-web.git",
                 revision: "4ae9b16f5835d37ab63dc4cb4064df4fef3574a4")
    ],
    targets: [
        .target(
            name: "BahaCore",
            dependencies: skipEnabled ? [.product(name: "SkipUI", package: "skip-ui")] : [],
            exclude: coreOnly ? ["Skip"] : [],
            resources: [.process("Resources")],
            plugins: skipEnabled ? [.plugin(name: "skipstone", package: "skip")] : []
        ),
        .testTarget(
            name: "BahaCoreTests",
            dependencies: ["BahaCore"] + (skipEnabled ? [.product(name: "SkipTest", package: "skip")] : []),
            path: "tests/BahaCoreTests",
            exclude: coreOnly ? ["Skip"] : [],
            plugins: skipEnabled ? [.plugin(name: "skipstone", package: "skip")] : []
        )
    ],
    swiftLanguageModes: [.v5]
)

if !coreOnly {
    package.products.insert(.library(name: "BahaPlus", type: .dynamic, targets: ["BahaPlus"]), at: 0)
    package.targets.append(.target(
        name: "BahaPlus",
        dependencies: [
            "BahaCore",
            .product(name: "SkipWeb", package: "skip-web")
        ] + (skipEnabled ? [.product(name: "SkipUI", package: "skip-ui")] : []),
        resources: [.process("Resources")],
        plugins: skipEnabled ? [.plugin(name: "skipstone", package: "skip")] : []
    ))
}
if skipDisabled {
    package.dependencies.removeAll {
        if case .sourceControl(_, let url, _) = $0.kind {
            return url.hasSuffix("/skip.git") || url.hasSuffix("/skip-ui.git")
        }
        return false
    }
}
