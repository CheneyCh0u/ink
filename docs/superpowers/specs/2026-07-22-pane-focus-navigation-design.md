# 相邻 pane 方向聚焦设计

关联 Issue：[GitHub #74](https://github.com/CheneyCh0u/ink/issues/74)

## 背景

Ink 已支持在一个标签内向左、右、上、下分屏，也能通过鼠标点击 pane 切换焦点，
但键盘只能创建和关闭 pane，不能在已有 pane 之间移动焦点。分屏较多时，用户必须把手
移到鼠标，打断连续的终端操作。

roadmap 的 P1-A 要求补齐 pane 间方向导航。本次使用 `Command-Option-方向键`，并在
“窗口”菜单提供同名命令，使快捷键可发现、可由 AppKit 正常路由和校验。

## 目标

- `Command-Option-←/→/↑/↓` 聚焦视觉上对应方向的相邻 pane。
- 嵌套、不同权重和 T 形布局中的选择结果符合屏幕几何关系，而不是布局树的父子关系。
- 切换后同步活动 pane、焦点边框、第一响应者和工作区快照。
- 目标方向没有相邻 pane 时不移动、不循环，也不发出提示音。
- 菜单项在设置页、单 pane 或对应方向无目标时禁用。
- 导航算法保持纯 Swift，不读取 AppKit frame；运行时只传入 workspace 尺寸和统一的
  divider 厚度，能够用单元测试完整验证。

## 非目标

本次不做以下扩展：

- 跨标签或跨窗口移动焦点。
- 到达边界后循环到另一侧。
- 维护最近使用顺序或焦点历史。
- Vim 风格按键、快捷键自定义或设置项。
- pane 重排、交换、缩放动画或焦点提示浮层。
- 改变鼠标点击聚焦、搜索栏或分屏创建行为。

## 方案选择

### 采用：从 `PaneLayout` 推导权重几何

纯模型查询从根节点的单位矩形 `(0, 0, 1, 1)` 开始；真实窗口查询则使用 workspace 的
当前宽高，并在每层切分时扣除与视图容器共享的 1pt divider 厚度。两者都按每个分组的
轴和权重递归切分，得到每个叶子 pane 的矩形，再以当前 pane 为原点筛选目标方向候选，
并按确定的几何评分选出一个 pane。

这一方案与实际布局使用同一棵树、同一组权重、同一 divider 常量和相同的余量吸收规则，
但不读取叶子 `NSView.frame`，因此不耦合 AppKit 布局完成时机。算法放在
`PaneLayout.swift`，只使用 `Double` 和值类型，保持模型可独立测试。workspace 尚无有效
尺寸的短暂阶段传入零尺寸，菜单保持禁用，不能把焦点切到尚不可见的 pane。

### 未采用：查找布局树中的结构兄弟

结构兄弟适合简单的单层分屏，但嵌套布局中“同一个父节点”不等于视觉相邻。T 形布局
尤其会得到不符合方向直觉的结果，因此不以树关系直接决定目标。

### 未采用：读取叶子 `NSView.frame`

真实 frame 能反映当前像素布局，但会把导航决策耦合到 AppKit 视图树、布局完成时机和
测试窗口。workspace 的宽高与 divider 厚度已经足以纯 Swift 重建同一几何，不需要把
叶子 frame 或 AppKit 类型传入模型。

## 快捷键与菜单

“窗口”菜单在会话切换命令之前增加四项：

| 菜单项 | 快捷键 | selector |
| --- | --- | --- |
| 聚焦左侧 pane | `⌘⌥←` | `focusPaneLeft(_:)` |
| 聚焦右侧 pane | `⌘⌥→` | `focusPaneRight(_:)` |
| 聚焦上方 pane | `⌘⌥↑` | `focusPaneUp(_:)` |
| 聚焦下方 pane | `⌘⌥↓` | `focusPaneDown(_:)` |

方向键使用 AppKit 的 Unicode 功能键值，modifier 固定为 `.command` 与 `.option`。
现有 `Command-D` 分屏状态机在空闲阶段会放行无关事件，因此这组组合键继续交给主菜单
处理，不新增本地事件监听，也不向 PTY 写入转义序列。

`MainWindowController.validateMenuItem(_:)` 把四个 selector 映射到对应方向，并询问
工作区当前是否存在目标。设置页显示期间一律禁用。动作方法本身也重复守卫设置页和目标
存在性，不能只依赖菜单校验。

## 归一化几何

### 数据表示

`PaneLayout.swift` 增加仅供 shell 模型使用的内部值类型，用四个 `Double` 保存矩形；
坐标既可表示单位矩形，也可表示运行时点数：

```swift
struct PaneNavigationRect: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
```

坐标与 `WorkspaceSplitContainerView.isFlipped == true` 保持一致：原点在左上，`x` 向右
增长，`y` 向下增长。这样 `.up` 与较小的 `y` 对应，`.down` 与较大的 `y` 对应，不需
在 UI 层转换坐标。

### 递归切分

`PaneLayout` 从给定根矩形递归收集 `(paneID, rect, ordinal)`：

1. `.leaf` 直接记录当前矩形。
2. `.leftRight` 按权重从左到右切分 `width`。
3. `.topBottom` 按权重从上到下切分 `height`。
4. 运行时每层先从可用轴长扣除 `dividerThickness × (childCount - 1)`，并在子节点之间
   推进同一厚度；单位矩形查询的 divider 为零。
5. 最后一个子节点吸收浮点余量，保证子矩形与 divider 一起完整覆盖父矩形。
6. `ordinal` 使用现有 `paneIDs` 相同的深度优先顺序，作为最终稳定排序键。

有效运行态的权重数量应与子节点数量相同、每项为有限正数。为了让导航在损坏或手工
构造的布局上仍有确定结果，几何推导沿用视图容器的防御行为：数量不匹配、非有限值、
非正数或总和无效时，对该分组使用等分权重。导航不修改原布局。

### 候选筛选

当前 pane 的矩形记为 `active`，候选记为 `candidate`，浮点比较使用一个固定小 epsilon。
宽或高不大于 epsilon 的零面积 pane 不能成为目标；若当前 pane 已被窗口压成零面积，
仍允许沿压缩轴跳到可见候选，避免键盘焦点困在不可见 pane。
候选必须在目标方向，且在垂直于移动方向的轴上有严格大于 epsilon 的重叠：

- 左：`candidate.maxX <= active.minX + epsilon`，并且 Y 轴正重叠。
- 右：`candidate.minX >= active.maxX - epsilon`，并且 Y 轴正重叠。
- 上：`candidate.maxY <= active.minY + epsilon`，并且 X 轴正重叠。
- 下：`candidate.minY >= active.maxY - epsilon`，并且 X 轴正重叠。

仅角点接触的对角 pane 没有正重叠，不是候选。当前 pane 自身始终排除。

### 候选评分

每个候选按以下元组升序排序；前两项之差不超过同一个 epsilon 时视为相等：

1. **轴向间距**：当前 pane 边缘到候选近侧边缘的非负距离。
2. **横向偏移**：两者在垂直轴上的中心点距离绝对值。
3. **稳定顺序**：递归收集时的深度优先 ordinal。

正常平铺布局中直接相邻 pane 的轴向间距通常为零；第一项仍能排除同方向上被其他 pane
隔开的目标。第二项优先选择与当前 pane 中心更对齐的候选。T 形布局中若上下两个候选
完全同分，则由第三项稳定选择布局树中靠前、也就是视觉上先出现的 pane。

`PaneLayout.neighbor(of:direction:) -> PaneID?` 封装完整推导与选择。当前 ID 不在布局中、
布局没有有效叶子或没有候选时返回 `nil`。

## 状态与响应者流转

### `TerminalTab`

`TerminalTab.focusNeighbor(direction:) -> Bool` 调用布局查询。找到目标后复用
`activate(_:)` 更新 `activePaneID` 并返回 `true`；没有目标时返回 `false`，状态不变。

单独保留 `canFocusNeighbor(direction:)`，只查询布局，不修改活动 pane，供菜单校验使用。
pane 数量很小，不引入缓存，也避免布局变化后维护失效状态。

### `TerminalWorkspaceViewController`

工作区增加同名查询和动作入口：

1. `canFocusNeighbor(direction:)` 把当前 workspace 宽高与共享 divider 厚度传给当前标签。
2. `focusNeighbor(direction:)` 使用同一运行时几何让标签切换活动 pane。
3. 成功后刷新所有 pane 的活动边框。
4. 调用现有 `onActivatePane`，让主窗口沿用既有的快照保存、标题和 chrome 刷新路径。
5. 将新活动 pane 的 `TerminalMetalView` 设为窗口第一响应者。

失败路径不调用回调、不变更第一响应者，也不调用 `NSBeep()`。成功路径只触发一次活动
回调。现有鼠标聚焦继续走 `activate(_:)`，不受影响。

搜索栏属于具体 pane 的临时 UI。方向导航只改变活动 pane 和终端第一响应者，不主动迁移
查询、不为目标 pane 打开搜索栏，也不增加新的全局搜索状态。

### `MainWindowController`

四个 `@objc` 动作只负责把 selector 映射成 `PaneSplitDirection` 并调用工作区，不复制
几何逻辑。设置页开启时直接返回。菜单验证同样通过工作区查询，因此菜单可见状态与实际
动作使用同一判断来源。

## 边界和确定性

- 单 pane：四个方向均返回 `nil`，菜单全部禁用。
- 外边界：对应方向返回 `nil`，焦点留在原 pane。
- 对角接触：无正交轴重叠，不跳转。
- 不同权重：按归一化边界和中心计算，不按子节点索引猜测。
- 嵌套同方向分组：无论布局是否已扁平化，递归几何结果一致。
- 完全同分：使用 DFS ordinal，结果不依赖字典顺序或 UUID。
- divider 差异：运行时按与 `WorkspaceSplitContainerView` 相同的 1pt 分隔线重建矩形。
- 极端压缩：零面积 pane 不成为目标，但零面积 active 可沿压缩轴逃到可见 pane。
- 设置页：命令禁用，直接调用 selector 也不改变后台终端焦点。

## 性能与内存

导航只在按键动作和菜单校验时遍历 pane，时间与叶子数量线性相关，常用规模为 1–4 个
pane。临时矩形数组只在查询期间存在，不进入每帧渲染、grid、scrollback 或 PTY I/O
路径，也不增加 per-cell 或 per-line 常驻内存。

本次不修改 `TerminalCore`、Metal renderer 或 `TerminalMetalView` 的绘制流程，因此不需要
为这一项单独运行 Instruments；完整功能收尾时仍按 roadmap 执行真实 120 Hz、ARC 和内存
验收。

## 测试策略

### `PaneLayoutTests`

- 单 pane 与四个外边界都返回 `nil`。
- 两 pane 左右、上下布局可双向移动。
- 2×2 嵌套布局在四个方向选择视觉相邻项。
- 不同权重布局仍以几何位置而非树深度选择。
- T 形布局优先中心更接近的候选；完全同分时按 DFS 顺序稳定选择。
- 只有角点接触的 pane 不会发生对角跳转。
- 无效权重使用等分回退且不修改布局。
- 不在布局中的 PaneID 返回 `nil`。
- 数学同分不受嵌套浮点舍入影响，仍按 DFS 顺序决胜。
- 运行时 viewport 与 divider 可改变理想权重几何的中心近邻选择。
- 压缩为零面积的目标被拒绝，零面积 active 仍可沿压缩轴逃到可见 pane。

### `TerminalTabTests`

- 有目标时更新 `activePaneID` 并返回 `true`。
- 到达边界时返回 `false` 且保持原活动 pane。
- `canFocusNeighbor` 不改变任何状态。

### `TerminalWorkspaceTests`

- 成功切换后只有目标 pane 显示焦点边框。
- 目标 `TerminalMetalView` 成为第一响应者。
- 成功时活动回调恰好触发一次，边界失败时不触发。

### 菜单命令测试

- “窗口”菜单包含四个正确标题、方向键 key equivalent 和 `Command-Option` modifier。
- selector 分别路由到正确方向。
- 单 pane、外边界和设置页中菜单项禁用；存在目标时启用。
- 现有 `Command-D` 分屏、`Command-Shift-↑/↓` 命令跳转和会话快捷键保持不变。

## 验收

自动验证至少执行：

```bash
swift test --no-parallel
swift build
```

随后在真实窗口构造左右、上下、2×2、T 形和不同权重布局，逐方向确认快捷键、菜单禁用、
焦点边框和输入落点一致。边界按键不得循环、响铃或把方向键发送给 PTY。
