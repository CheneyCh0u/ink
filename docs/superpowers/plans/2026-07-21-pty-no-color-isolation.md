# PTY 宿主颜色环境隔离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 阻止启动 Ink 的宿主 NO_COLOR 泄漏到 PTY 子进程，同时保留其他环境变量与终端能力声明。

**Architecture:** 将 PTY 子环境构造提取为 PTYSession.childEnvironment(from:) 纯函数，start() 只消费其结果。测试直接覆盖环境边界，不启动真实 shell，也不依赖测试进程的实际环境。

**Tech Stack:** Swift 6、Foundation、Swift Testing、SwiftPM。

## Global Constraints

- InkPTY 不引入 AppKit 或 Metal。
- 只清理宿主 NO_COLOR，不清理 FORCE_COLOR 或 CLICOLOR。
- 用户在 shell 启动脚本中重新设置 NO_COLOR 的能力不受影响。
- 不新增第三方依赖，不修改调色板、VT/SGR 解析或 Metal 渲染。

---

### Task 1: 隔离 PTY 子进程的 NO_COLOR

**Files:**
- Modify: Sources/InkPTY/PTYSession.swift:46-60
- Test: Tests/InkPTYTests/PTYSessionTests.swift

**Interfaces:**
- Consumes: 宿主环境 [String: String]。
- Produces: static func childEnvironment(from hostEnvironment: [String: String]) -> [String: String]。

- [ ] **Step 1: 写入失败回归测试**

    @Test("PTY 子环境移除宿主 NO_COLOR 并保留其他变量")
    func childEnvironmentRemovesHostNoColor() {
        let environment = PTYSession.childEnvironment(from: [
            "NO_COLOR": "1",
            "TERM": "dumb",
            "COLORTERM": "",
            "LANG": "en_US.UTF-8",
            "INK_SENTINEL": "preserved",
        ])

        #expect(environment["NO_COLOR"] == nil)
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "ink")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["INK_SENTINEL"] == "preserved")
    }

- [ ] **Step 2: 运行测试并确认按预期失败**

Run: swift test --filter childEnvironmentRemovesHostNoColor
Expected: 编译失败，提示 PTYSession 没有 childEnvironment 成员。

- [ ] **Step 3: 实现最小环境构造函数并接入 start()**

    static func childEnvironment(
        from hostEnvironment: [String: String]
    ) -> [String: String] {
        var environment = hostEnvironment
        environment.removeValue(forKey: "NO_COLOR")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ink"
        if environment["LANG"] == nil {
            environment["LANG"] = "zh_CN.UTF-8"
        }
        return environment
    }

将 start() 中的环境复制和覆盖替换为：

    let environment = Self.childEnvironment(
        from: ProcessInfo.processInfo.environment
    )

- [ ] **Step 4: 运行定向测试与全量验证**

Run: swift test --filter childEnvironmentRemovesHostNoColor
Expected: 1 test passed。

Run: swift test && swift build -c release --product ink && git diff --check
Expected: 全部测试通过、Release 构建成功、补丁格式无错误。

- [ ] **Step 5: 提交实现**

    git add Sources/InkPTY/PTYSession.swift Tests/InkPTYTests/PTYSessionTests.swift
    git commit -m "fix(pty): 隔离宿主颜色禁用变量" \
      -m "避免自动化宿主的 NO_COLOR 关闭终端应用 ANSI 配色。" \
      -m "Refs #46"

### Task 2: 打包并执行安装版运行时验证

**Files:**
- Package: scripts/package-app.sh
- Install: /Applications/Ink.app

**Interfaces:**
- Consumes: Task 1 通过验证的 Release 源码。
- Produces: ad-hoc 签名的通用架构 Ink.app 测试安装包。

- [ ] **Step 1: 使用合法本地测试标签打包**

Run: scripts/package-app.sh v2026.07.21-46 temporary-output-dir
Expected: arm64 与 x86_64 构建成功，ZIP 与 SHA-256 生成。

- [ ] **Step 2: 校验并替换安装包**

校验 SHA-256、签名、Bundle ID 与双架构；关闭旧 Ink，替换 /Applications/Ink.app，不保留 /Applications 内备份。

- [ ] **Step 3: 从仍含 NO_COLOR=1 的宿主启动安装版并验证环境**

验证 Ink 进程可带 NO_COLOR=1，但新 PTY 的 shell 与 Claude Code 不再含 NO_COLOR；同时确认 TERM=xterm-256color 与 COLORTERM=truecolor。

- [ ] **Step 4: 推送并创建 PR**

推送 agent/issue-46-pty-no-color，创建目标为 main 且正文包含唯一 Closes #46 的 PR；不合并、不发布。
