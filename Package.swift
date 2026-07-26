// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "RPG-TEXT",
    platforms: [
        .iOS(.v16)
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
            path: "App/Sources/AppProject"   // ⭐ 指向你的源代码目录
        )
    ]
)
