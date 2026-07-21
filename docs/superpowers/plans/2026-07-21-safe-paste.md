# 安全粘贴实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 多行或包含控制字符的剪贴板文本写入 PTY 前必须确认，并允许安全地转为单行。

**Architecture:** 在 `InkTerminalView` 中新增不依赖窗口的纯粘贴策略，负责风险分类、行数统计、单行净化和最终 PTY 编码。`TerminalMetalView` 只读取剪贴板、请求确认并发送策略产出的字节；`NSAlert` 通过可替换协议隔离，测试不弹真实窗口。

**Tech Stack:** Swift 6、AppKit、swift-testing；不新增第三方依赖。

## Global Constraints

- `TerminalCore` 不得引入 AppKit 或 Metal。
- 不给 cell 或 scrollback 增加字段，不触碰渲染热路径。
- 保留 bracketed paste 包裹和 `ESC [ 201 ~` 结束标记过滤。
- 不记录粘贴内容，不建立剪贴板历史。
- 普通单行文本继续直接粘贴。

---

### Task 1: 纯粘贴安全策略

**Files:**
- Create: `Sources/InkTerminalView/SafePaste.swift`
- Create: `Tests/InkTerminalViewTests/SafePasteTests.swift`

**Interfaces:**
- Produces: `SafePaste.assessment(for:bracketedPaste:) -> SafePasteAssessment?`
- Produces: `SafePaste.singleLine(_:) -> String`
- Produces: `SafePaste.encoded(_:bracketedPaste:) -> Data`

- [ ] **Step 1: 写失败测试**

覆盖普通 Unicode 单行、多行的 CR/LF/CRLF 计数、Tab/ESC/NUL/DEL/C1 分类、未开启 bracketed paste 的附加风险、单行净化，以及两种模式的最终编码。

- [ ] **Step 2: 验证测试因缺少 `SafePaste` 失败**

Run: `swift test --filter SafePasteTests`

Expected: FAIL，提示 `SafePaste` 等符号不存在。

- [ ] **Step 3: 写最小实现**

逐个 Unicode scalar 扫描一次：CRLF 只算一个换行；换行和 Tab 在单行模式下变成空格；其他 C0、DEL 与 C1 控制字符移除。编码前无条件过滤 bracketed paste 结束标记，开启模式时再加 `ESC[200~` / `ESC[201~`。

- [ ] **Step 4: 验证策略测试通过**

Run: `swift test --filter SafePasteTests`

Expected: PASS。

### Task 2: 确认协调与终端视图接入

**Files:**
- Modify: `Sources/InkTerminalView/SafePaste.swift`
- Modify: `Sources/InkTerminalView/TerminalMetalView.swift:583`
- Modify: `Tests/InkTerminalViewTests/SafePasteTests.swift`

**Interfaces:**
- Produces: `SafePasteChoice` 的 `.paste`、`.singleLine`、`.cancel`
- Produces: `SafePastePresenting.choose(for:) -> SafePasteChoice`
- Consumes: Task 1 的风险评估、单行净化和编码接口

- [ ] **Step 1: 写失败测试**

注入记录型 presenter，验证安全单行不弹确认；危险文本分别选择原样粘贴、转为单行和取消；检查写入 PTY 的完整字节。

- [ ] **Step 2: 验证新测试因缺少协调逻辑失败**

Run: `swift test --filter SafePasteTests`

Expected: FAIL，原因是 presenter 未被调用或终端视图仍直接发送文本。

- [ ] **Step 3: 接入最小实现**

`TerminalMetalView.paste(_:)` 将剪贴板文本交给内部 `paste(text:)`。有风险时调用 presenter；选择原样粘贴走既有编码，选择转单行先净化，取消不调用 `onInput`。生产 presenter 使用系统 `NSAlert`，显示行数和具体风险，并让“转为单行”成为默认安全动作。

- [ ] **Step 4: 验证接入测试通过**

Run: `swift test --filter SafePasteTests`

Expected: PASS。

### Task 3: 全量验证和交付

**Files:**
- Modify: `docs/superpowers/plans/2026-07-21-safe-paste.md`（勾选实际完成步骤）

- [ ] **Step 1: 运行全量测试**

Run: `swift test`

Expected: 0 failures。

- [ ] **Step 2: 运行构建**

Run: `swift build`

Expected: exit 0 且无新增警告。

- [ ] **Step 3: 检查差异**

Run: `git diff --check && git status --short`

Expected: 无空白错误，只有 Issue #56 范围内文件。

- [ ] **Step 4: 提交**

```bash
git add Sources/InkTerminalView/SafePaste.swift Sources/InkTerminalView/TerminalMetalView.swift Tests/InkTerminalViewTests/SafePasteTests.swift docs/superpowers/plans/2026-07-21-safe-paste.md
git commit -m "feat(terminal): 阻止危险粘贴直接写入 PTY" -m "在多行或控制字符粘贴前给出风险确认，并允许净化为单行，避免误执行命令。\n\nRefs #56"
```

- [ ] **Step 5: 推送并创建 PR**

Run: `git push -u origin agent/issue-56-safe-paste`，随后创建目标为 `main` 且正文含 `Closes #56` 的 PR。
