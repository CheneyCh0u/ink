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
        // 配置：极小 TOML 子集解析 + 热重载。零第三方依赖。
        .target(
            name: "InkConfig"
        ),
        // 终端内容区：NSView + CAMetalLayer 自绘，glyph atlas 渲染。
        .target(
            name: "InkTerminalView",
            dependencies: ["TerminalCore", "InkDesign"],
            // swift build 不编译 .metal，以源码进 bundle、TerminalRenderer 启动时编译。
            resources: [.copy("Shaders.metal")]
        ),
        // 外壳 UI：窗口、侧边栏、标签。
        .target(
            name: "InkShell",
            dependencies: ["InkDesign", "TerminalCore", "InkPTY", "InkTerminalView", "InkConfig"]
        ),
        // 可执行入口。
        .executableTarget(
            name: "ink",
            dependencies: ["InkShell"],
            // SwiftPM 运行时用同一份 icns 设置 Dock 图标；正式 .app 打包也复用它。
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        // 内存基准：灌 10 万行实测 footprint，M6 验收用（docs/perf.md）。
        .executableTarget(
            name: "ink-bench",
            dependencies: ["TerminalCore"]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"]
        ),
        .testTarget(
            name: "InkTerminalViewTests",
            dependencies: ["InkTerminalView"]
        ),
        .testTarget(
            name: "InkConfigTests",
            dependencies: ["InkConfig"]
        ),
    ]
)
