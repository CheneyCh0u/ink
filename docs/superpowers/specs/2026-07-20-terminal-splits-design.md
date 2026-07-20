# 标签内终端分屏设计

关联 Issue：[GitHub #29](https://github.com/CheneyCh0u/ink/issues/29)

## 目标

一个标签可以承载多个终端 pane。用户从当前 pane 向右或向下创建新终端，拖动分隔线调整空间，并用 `Command-W` 关闭当前 pane。布局可以递归嵌套，不设置固定数量上限。

常用规模按 1 到 4 个可见 pane 设计和验收。窗口空间不足以容纳最小终端网格时，不再允许继续分屏。

## 范围

本次实现包含：

- `Command-D` 向右分屏，`Command-Shift-D` 向下分屏。
- 左右与上下布局可以任意嵌套。
- 原生分隔线拖动和分割比例回写。
- pane 焦点管理与当前 pane 提示。
- `Command-W` 关闭当前 pane，最后一个 pane 关闭时移除标签。
- 标签关闭按钮关闭整个标签及其中所有 pane。
- 新 pane 继承当前前台进程的工作目录，查询失败时回退到项目目录。
- shell 自行退出后的布局收拢和焦点迁移。
- 1 pane 与 4 pane 的内存和渲染开销对比。

本次不包含布局持久化、会话恢复、快捷键自定义、跨标签移动 pane、pane 拖放重排和独立 pane 标题栏。这些能力需要单独设计。

## 方案取舍

### 采用递归 NSSplitView，每个 pane 一个 Metal 视图

每个可见 pane 使用独立的 `TerminalMetalView`，布局由递归嵌套的 `NSSplitView` 组成。AppKit 负责分隔线命中、拖动和约束，外壳只维护布局树与视图树的一致性。

单个窗口的 drawable 总面积主要取决于窗口面积。分成四块后不会简单变成原来的四倍。每个额外 pane 会增加一张 2048 × 2048 的单色 glyph atlas，约 4 MB；遇到彩色 emoji 时，还可能按 pane 懒分配一张约 16 MB 的彩色 atlas。常用上限为四个 pane 时，这个成本可以接受，但必须实测。

### 未采用单 Metal 画布

单画布可以共享 layer、atlas 和 draw call，但需要自建递归布局、分隔线拖动、事件路由、输入法定位和每个 pane 的裁剪。它会把分屏功能扩展成渲染架构重写。当前使用规模不足以抵消这部分复杂度。

### 未提前共享渲染资源

多个 Metal 视图共享 atlas 或 pipeline，需要拆分 `TerminalRenderer` 的资源所有权和可变缓存。先保留现有 renderer 边界。性能验证若显示重复 atlas 已成为主要内存来源，再通过独立 Issue 设计共享资源。

## 数据模型

当前 `Project.sessions` 把标签和终端会话视为同一个对象。分屏后改为 `Project.tabs`，每个 `TerminalTab` 管理一个标签内的布局和会话。

```swift
@MainActor
final class TerminalTab {
    var layout: PaneLayout
    var panes: [PaneID: TerminalPane]
    var activePaneID: PaneID
    var customName: String?
}

struct PaneID: Hashable, Sendable {
    let rawValue: UUID
}

struct SplitID: Hashable, Sendable {
    let rawValue: UUID
}

indirect enum PaneLayout: Equatable, Sendable {
    case leaf(PaneID)
    case split(
        id: SplitID,
        axis: PaneSplitAxis,
        ratio: Double,
        first: PaneLayout,
        second: PaneLayout
    )
}

enum PaneSplitAxis: Equatable, Sendable {
    case leftRight
    case topBottom
}
```

`TerminalPane` 持有一个 `TerminalSession`，不持有 AppKit 视图。每个分支使用稳定的 `SplitID`，供视图代理把拖动结果写回正确节点。比例用 `Double` 保存，视图边界再转换为 `CGFloat`。`PaneLayout` 是纯数据结构，负责以下操作：

- 把目标叶节点替换为分支节点，旧 pane 放在左侧或上方，新 pane 放在右侧或下方。
- 删除目标叶节点，并把兄弟节点提升到父节点的位置。
- 查找目标 pane 的路径和兄弟子树。
- 在兄弟子树内选择离原分隔线最近的叶节点，作为关闭后的焦点。
- 保存每个分支的分割比例。

布局树不依赖 `AppKit`、Metal 或 PTY，单元测试可以覆盖全部结构变化。

## 视图与控制器

`TerminalWorkspaceViewController` 只展示当前标签。它根据 `PaneLayout` 递归创建视图：

- 叶节点创建 `TerminalPaneView`，内部包含一个 `TerminalMetalView` 和当前 pane 的细边框。
- 分支节点创建 `NSSplitView`。左右分屏使用竖直分隔线，上下分屏使用水平分隔线。
- 用户拖动分隔线后，将实际比例归一化到 0 到 1，并写回对应布局节点。

`TerminalPaneView` 在鼠标按下和成为第一响应者时通知工作区更新 `activePaneID`。多 pane 时，当前 pane 显示 1 pt 系统强调色内边框；单 pane 时隐藏边框。

工作区维护 `PaneID` 到可见视图的弱引用映射。某个 `TerminalSession` 有新输出时，仅标记对应的可见视图为脏；后台标签没有终端视图，只更新标签标题所需的状态。

## 标签切换与资源生命周期

只有当前标签创建终端视图。切换标签时，工作区移除旧视图树并按新标签的布局树重建。PTY、parser、grid 和 scrollback 保存在 `TerminalSession` 中，不受视图重建影响。

移出窗口的 `TerminalMetalView` 会停止 `CADisplayLink`，释放 renderer、glyph atlas、实例缓冲和 `CAMetalLayer`。切回标签后，滚动位置、选区和输入法预编辑会重置，这与当前切换会话时的行为一致。

字体、字号、行高、光标、Option 键和选中即复制等配置，由工作区统一应用到所有可见视图。新建或重建的视图读取当前配置。

## 创建分屏

`Command-D` 调用 `splitActivePane(.leftRight)`，`Command-Shift-D` 调用 `splitActivePane(.topBottom)`。处理顺序如下：

1. 确认当前标签、当前 pane 和可见网格存在。
2. 确认分割后两侧都能保留最小网格。最小值为 10 列 × 3 行，外加内容边距和分隔线。
3. 查询当前 pane 的实时工作目录。查询失败、目录不存在或结果不是目录时，使用项目目录。
4. 以新区域预计尺寸创建并启动 `TerminalSession`。
5. PTY 启动成功后再修改布局树，避免失败时留下空 pane。
6. 新 pane 插入右侧或下方，初始比例为 0.5，并成为当前 pane。
7. 重建受影响的视图子树，把焦点交给新 pane。

PTY 启动失败时显示现有的 `NSAlert`，原布局和焦点保持不变。

## 工作目录继承

`PTYSession` 增加只读的 `foregroundWorkingDirectory()`。它先通过 `tcgetpgrp` 获取前台进程组，再用 macOS 的进程信息接口读取进程工作目录。

查询只在用户创建分屏时同步执行一次，不进入渲染或输出热路径。接口返回可选路径，不抛错。以下情况返回 `nil`：

- PTY 尚未启动或已经关闭。
- 前台进程组不可用。
- 系统进程查询失败。
- 返回路径为空、已删除或不是目录。

`TerminalSession` 透传这个查询。`MainWindowController` 负责应用项目目录回退，不把项目概念引入 `InkPTY`。

## 关闭与退出

`Command-W` 只操作 `activePaneID`：

- 标签有多个 pane 时，先从布局树移除当前叶节点并选出兄弟子树中的接替 pane，再解除退出回调并终止对应 PTY。
- 当前是最后一个 pane 时，移除整个标签。
- 当前是窗口内最后一个标签时，沿用现有行为关闭窗口。

标签栏关闭按钮是标签级操作。它先解除标签内所有 session 的更新和退出回调，再逐个终止 PTY，最后一次性移除标签，避免退出事件重入布局修改。

shell 自行退出时，通过 session 到 `PaneID` 的映射找到叶节点，行为与关闭当前 pane 相同。若退出的不是当前 pane，当前焦点保持不变；若退出的是当前 pane，则按兄弟子树选择规则迁移焦点。

关闭后优先聚焦被提升的兄弟子树中靠近原分隔线的叶节点。该规则只依赖布局树，不依赖屏幕坐标，嵌套布局下仍然稳定。

## 标签标题与现有命令

标签标题优先级调整为：用户设置的标签名、当前 pane 的 OSC 标题、项目路径。标签重命名作用于 `TerminalTab.customName`，不再写入单个 `TerminalSession`。

`Command-T` 创建一个只有单 pane 的新标签。`Command-1` 到 `Command-9`、下一个标签和上一个标签仍按标签切换，不在 pane 间循环。

设置页显示期间，分屏和关闭 pane 菜单项不可用，避免隐藏工作区仍处理焦点命令。

## 分隔比例

每个分支保存一个 0 到 1 的比例，表示第一个子节点占可用长度的份额。创建分屏时使用 0.5。拖动结束和布局变化时读取 `NSSplitView` 的实际 frame，扣除 divider 厚度后计算比例。

重建视图树时按比例设置 divider 位置。窗口缩放由 AppKit 保持比例和最小尺寸；布局完成后把实际比例写回模型，避免模型记录无法满足的尺寸。

本次不持久化比例。比例只在标签运行期间保留，应用退出后随会话一起销毁。

## 性能与内存

这次不修改 `TerminalCore` 热路径，也不修改 `TerminalRenderer.buildInstances`。可见 pane 数增加后，每个脏 pane 各提交一次 draw call。

验收使用 1280 × 800、2x 缩放窗口，并记录硬件与系统版本：

- 1 pane 和 4 pane 空闲 30 秒后的进程 footprint。
- 4 pane 全部进入过普通 ASCII 输出后的 footprint，用于观察单色 atlas 成本。
- 4 pane 全部出现彩色 emoji 后的 footprint，记录彩色 atlas 最坏增量。
- 四个 pane 同时运行高速输出时，用 Instruments Time Profiler 和 Metal System Trace 检查主线程耗时、帧间隔和每帧提交次数。

结果写入 `docs/perf.md`。若四 pane 空闲增量明显超过三张单色 atlas、分割后的 drawable 面积和固定对象开销之和，需要在合入前定位来源。若 atlas 重复成为主要问题，另建 Issue 设计共享资源，不在本次改动中临时扩展 renderer 边界。

## 测试

`InkShellTests` 增加以下覆盖：

- 左右分割把新 pane 放在第二子节点，活动 pane 切到新 pane。
- 上下分割使用正确方向。
- 在嵌套布局中继续分割任意叶节点。
- 关闭左侧、右侧、上方和下方叶节点时正确提升兄弟节点。
- 关闭嵌套分支中的当前 pane 后，焦点迁移到靠近原分隔线的叶节点。
- 关闭非当前 pane 时保持当前焦点。
- 最后一个 pane 关闭后移除标签。
- 拖动比例回写，重建视图后恢复 divider 位置。
- 标签切换只保留当前标签的终端视图。
- `Command-D`、`Command-Shift-D` 和 `Command-W` 连接到正确 action。

`InkPTYTests` 增加工作目录查询测试。测试启动一个可控子进程并改变目录，验证返回路径；无前台进程和进程退出后的查询返回 `nil`。

完整验证执行：

```bash
swift test
swift build
```

## 文档影响

分屏已经在 `docs/roadmap.md` 的 P1 和 `docs/tech-stack.md` 的 M5 中，不需要扩大 roadmap 范围。实现完成后只补充 `docs/perf.md` 的测量结果。
