# 标签内终端分屏设计

关联 Issue：[GitHub #29](https://github.com/CheneyCh0u/ink/issues/29)

## 目标

一个标签可以承载多个终端 pane。用户可以从当前 pane 向上、下、左、右创建新终端，拖动分隔线调整空间，并用 `Command-W` 关闭当前 pane。布局可以递归嵌套，不设置固定数量上限。

常用规模按 1 到 4 个可见 pane 设计和验收。窗口空间不足以容纳最小终端网格时，不再允许继续分屏。

## 范围

本次实现包含：

- `Command-D` 松开时默认向右分屏。按住 `Command-D` 再按方向键时，向对应方向分屏。
- 上、下、左、右四种插入方向。
- 左右与上下布局可以任意嵌套。
- 原生分隔线拖动和分组权重回写。
- pane 焦点管理与当前 pane 提示。
- `Command-W` 关闭当前 pane，最后一个 pane 关闭时移除标签。
- 标签关闭按钮关闭整个标签及其中所有 pane。
- 新 pane 继承当前前台进程的工作目录，查询失败时回退到项目目录。
- shell 自行退出后的布局收拢和焦点迁移。
- 1 pane 与 4 pane 的内存和渲染开销对比。

本次不包含布局持久化、会话恢复、快捷键自定义、跨标签移动 pane、pane 拖放重排和独立 pane 标题栏。这些能力需要单独设计。

## 方案取舍

### 采用分组式 NSSplitView，每个 pane 一个 Metal 视图

每个可见 pane 使用独立的 `TerminalMetalView`。连续同方向的 pane 由一个多子项 `NSSplitView` 管理，方向变化时才递归嵌套新的分组。AppKit 负责分隔线命中和拖动，外壳维护布局树与视图树的一致性。

同方向分组避免多个嵌套 `NSSplitView` 在自动布局时互相压缩。一个上下分组可以直接容纳多个纵向排列的 pane，一个左右分组可以直接容纳多个横向排列的 pane。常用的四 pane 布局只会在方向变化处增加视图层级。

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
    case group(
        id: SplitID,
        axis: PaneSplitAxis,
        weights: [Double],
        children: [PaneLayout]
    )
}

enum PaneSplitAxis: Equatable, Sendable {
    case leftRight
    case topBottom
}

enum PaneSplitDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}
```

`TerminalPane` 持有一个 `TerminalSession`，不持有 AppKit 视图。每个分组使用稳定的 `SplitID`，供视图代理把拖动结果写回正确节点。`weights` 与 `children` 数量相同，所有权重为正数并归一化为 1。同方向子分组必须合并到父分组，只有方向变化时才增加层级。视图边界再把权重转换为 `CGFloat`。`PaneLayout` 是纯数据结构，负责以下操作：

- 在同方向父分组中插入新 pane，并把目标 pane 的权重平分给两个 pane。
- 方向变化时，把目标叶节点替换为新的两子项分组。
- 左、上分屏把新 pane 插在目标 pane 前面；右、下分屏插在后面。
- 删除目标叶节点并移除对应权重，随后重新归一化。分组只剩一个子节点时，提升该节点。
- 查找目标 pane 的路径和相邻子树。
- 在相邻子树内选择离原分隔线最近的叶节点，作为关闭后的焦点。
- 保存每个分组内所有 pane 的相对权重。

布局树不依赖 `AppKit`、Metal 或 PTY，单元测试可以覆盖全部结构变化。

## 视图与控制器

`TerminalWorkspaceViewController` 只展示当前标签。它根据 `PaneLayout` 创建视图：

- 叶节点创建 `TerminalPaneView`，内部包含一个 `TerminalMetalView` 和当前 pane 的细边框。
- 分组节点创建多子项 `NSSplitView`。左右分屏使用竖直分隔线，上下分屏使用水平分隔线。
- 用户拖动分隔线后，读取分组内所有子视图尺寸，将结果归一化并写回对应布局节点。
- `WorkspaceSplitView` 跟踪 divider 的鼠标拖动，只在 mouse-up 时提交新权重。自动布局和窗口缩放只调整视图，不回写临时的 0 或 1。

`TerminalPaneView` 在鼠标按下和成为第一响应者时通知工作区更新 `activePaneID`。多 pane 时，当前 pane 显示 1 pt 系统强调色内边框；单 pane 时隐藏边框。

工作区维护 `PaneID` 到可见视图的弱引用映射。某个 `TerminalSession` 有新输出时，仅标记对应的可见视图为脏；后台标签没有终端视图，只更新标签标题所需的状态。

## 标签切换与资源生命周期

只有当前标签创建终端视图。切换标签时，工作区移除旧视图树并按新标签的布局树重建。PTY、parser、grid 和 scrollback 保存在 `TerminalSession` 中，不受视图重建影响。

移出窗口的 `TerminalMetalView` 会停止 `CADisplayLink`，释放 renderer、glyph atlas、实例缓冲和 `CAMetalLayer`。切回标签后，滚动位置、选区和输入法预编辑会重置，这与当前切换会话时的行为一致。

字体、字号、行高、光标、Option 键和选中即复制等配置，由工作区统一应用到所有可见视图。新建或重建的视图读取当前配置。

## 分屏快捷键

系统菜单无法表达 `Command-D` 加方向键的组合，因此由窗口级按键状态机处理：

- 按下 `Command-D` 时进入待定状态，不立即分屏。
- D 键松开前没有收到方向键，松开时默认向右分屏。
- D 键仍按住时收到方向键，立即向对应方向分屏，并把本次组合标记为已消费。
- 方向键已经触发后，松开 D 不再额外向右分屏。
- 一次组合只接受第一个方向键，忽略 D 的自动重复事件。
- Command 键先松开、焦点离开终端、窗口失焦或进入设置页时取消待定状态。

菜单保留上、下、左、右四个分屏动作，方便发现功能和点击执行。菜单不声明复合快捷键，避免 AppKit 在状态机判断方向前立即执行默认分屏。

## 创建分屏

快捷键状态机或菜单动作最终调用 `splitActivePane(direction:)`。处理顺序如下：

1. 确认当前标签、当前 pane 和可见网格存在。
2. 确认分割后两侧都能保留最小网格。最小值为 10 列 × 3 行，外加内容边距和分隔线。
3. 查询当前 pane 的实时工作目录。查询失败、目录不存在或结果不是目录时，使用项目目录。
4. 以新区域预计尺寸创建并启动 `TerminalSession`。
5. PTY 启动成功后再修改布局树，避免失败时留下空 pane。
6. 新 pane 按方向插入当前 pane 前方或后方，并成为当前 pane。同方向父分组平分目标权重，方向变化时创建权重各为 0.5 的新分组。
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

- 标签有多个 pane 时，先从布局树移除当前叶节点并选出相邻子树中的接替 pane，再解除退出回调并终止对应 PTY。
- 当前是最后一个 pane 时，移除整个标签。
- 当前是窗口内最后一个标签时，沿用现有行为关闭窗口。

标签栏关闭按钮是标签级操作。它先解除标签内所有 session 的更新和退出回调，再逐个终止 PTY，最后一次性移除标签，避免退出事件重入布局修改。

shell 自行退出时，通过 session 到 `PaneID` 的映射找到叶节点，行为与关闭当前 pane 相同。若退出的不是当前 pane，当前焦点保持不变；若退出的是当前 pane，则按相邻子树选择规则迁移焦点。

关闭后优先聚焦同一分组中与被关闭 pane 相邻的叶节点。分组收拢时，选择被提升子树中靠近原分隔线的叶节点。该规则只依赖布局树，不依赖屏幕坐标。

## 标签标题与现有命令

标签标题优先级调整为：用户设置的标签名、当前 pane 的 OSC 标题、项目路径。标签重命名作用于 `TerminalTab.customName`，不再写入单个 `TerminalSession`。

`Command-T` 创建一个只有单 pane 的新标签。`Command-1` 到 `Command-9`、下一个标签和上一个标签仍按标签切换，不在 pane 间循环。

设置页显示期间，分屏和关闭 pane 菜单项不可用，避免隐藏工作区仍处理焦点命令。

## 分隔权重

每个分组保存一组归一化权重，表示各子节点占可用长度的份额。创建两子项分组时使用 `[0.5, 0.5]`。在现有分组中插入 pane 时，只平分目标 pane 的权重，其他 pane 的权重不变。

重建视图树时按权重依次设置 divider 位置。窗口缩放由 AppKit 调整当前 frame，不把构建期和自动布局产生的临时尺寸写回模型。用户拖动 divider 后，工作区读取全部子视图尺寸并更新权重。

本次不持久化权重。权重只在标签运行期间保留，应用退出后随会话一起销毁。

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

- 左、上分割把新 pane 插在目标 pane 前面，右、下分割插在后面，活动 pane 切到新 pane。
- 连续同方向分割复用一个多子项分组，所有 pane 都保持可见尺寸。
- 方向变化时创建嵌套分组，并能继续分割任意叶节点。
- 关闭左侧、右侧、上方和下方叶节点时正确重排剩余子节点。
- 关闭嵌套分组中的当前 pane 后，焦点迁移到靠近原分隔线的叶节点。
- 关闭非当前 pane 时保持当前焦点。
- 最后一个 pane 关闭后移除标签。
- 拖动权重回写，重建视图后恢复 divider 位置；自动布局不污染权重。
- 标签切换只保留当前标签的终端视图。
- 单独按下并松开 `Command-D` 时向右分屏。
- 按住 `Command-D` 再按四个方向键时，只执行对应方向一次。
- 自动重复、窗口失焦和设置页会正确取消待定组合。
- `Command-W` 连接到关闭当前 pane 的 action。

`InkPTYTests` 增加工作目录查询测试。测试启动一个可控子进程并改变目录，验证返回路径；无前台进程和进程退出后的查询返回 `nil`。

完整验证执行：

```bash
swift test
swift build
```

## 文档影响

分屏已经在 `docs/roadmap.md` 的 P1 和 `docs/tech-stack.md` 的 M5 中，不需要扩大 roadmap 范围。实现完成后只补充 `docs/perf.md` 的测量结果。
