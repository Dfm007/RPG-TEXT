// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "AppProject",
    products: [
        .library(name: "AppProject", targets: ["AppProject"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(
            name: "AppProject",
            dependencies: ["ZIPFoundation"],
            path: "App/Sources/AppProject"
        )
    ]
)
