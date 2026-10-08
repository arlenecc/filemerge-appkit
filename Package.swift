// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FileMerge",
    targets: [
        // 核心逻辑：纯 Objective-C 库（扫描/哈希/排重/合并/校验/进度）
        .target(
            name: "FileMergeCore",
            path: "Sources/FileMergeCore"
        ),
        // 图形界面：AppKit (Objective-C)
        .target(
            name: "FileMergeUI",
            dependencies: ["FileMergeCore"],
            path: "Sources/FileMergeUI"
        ),
        // 可执行入口
        .executableTarget(
            name: "FileMergeApp",
            dependencies: ["FileMergeUI", "FileMergeCore"],
            path: "Sources/FileMergeApp"
        ),
        // 单一测试目标（Swift swift-testing 驱动 ObjC 生产代码）
        .testTarget(
            name: "FileMergeCoreTests",
            dependencies: ["FileMergeUI", "FileMergeCore"],
            path: "Tests/FileMergeCoreTests"
        ),
    ]
)
