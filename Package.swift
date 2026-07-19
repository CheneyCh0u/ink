// swift-tools-version: 6.0
import PackageDescription

// 分层见 CLAUDE.md：TerminalCore 纯 Swift，不得依赖 AppKit / Metal。
// 依赖方向自上而下：ink → InkShell → (InkDesign, TerminalCore, InkPTY)。
let package = Package(
    name: "ink",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        // VT 解析、grid、scrollback。可脱离窗口做单元测试。
        .target(
            name: "TerminalCore"
        ),
        // forkpty + Dispatch I/O。只依赖 Darwin，不依赖 UI。
        .target(
            name: "InkPTY"
        ),
        // 全局视觉 token 与终端调色板。
        .target(
            name: "InkDesign"
        ),
        // 外壳 UI：窗口、侧边栏、标签、终端视图。
        .target(
            name: "InkShell",
            dependencies: ["InkDesign", "TerminalCore", "InkPTY"]
        ),
        // 可执行入口。
        .executableTarget(
            name: "ink",
            dependencies: ["InkShell"]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"]
        ),
    ]
)
