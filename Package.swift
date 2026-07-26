// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "RPG-TEXT",
    platforms: [
        .iOS(.v15)  // ⭐ 改为 v15（兼容旧版本 Swift）
    ],
    products: [
        .library(name: "RPG-TEXT", targets: ["RPG-TEXT"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(
            name: "RPG-TEXT",
            dependencies: ["ZIPFoundation"],
            path: "App/Sources/AppProject"
        )
    ]
)
