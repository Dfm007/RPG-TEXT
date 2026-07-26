// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "RPG-TEXT", // 这里替换为你的项目名
    dependencies: [
        // 添加 ZIPFoundation 依赖
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "RPG-TEXT", // 这里替换为你的 Target 名
            dependencies: ["ZIPFoundation"] // 在依赖中引用
        ),
    ]
)
