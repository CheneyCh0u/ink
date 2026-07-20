# 当前 pane 历史搜索设计

Issue：#31
状态：设计已确认，等待规格复核

## 背景与目标

Ink 已支持一个标签内递归分屏。用户需要在当前聚焦 pane 中搜索已经显示过的
内容，而不是在整个标签或所有分屏之间搜索。

本功能提供：

- `Command-F` 在当前聚焦 pane 内打开搜索条；
- 搜索该 pane 的 scrollback 与当前屏幕；
- 显示当前结果序号与总数；
- 使用按钮或键盘循环跳转上一个、下一个结果；
- 自动滚动到历史结果，并在 Metal 终端中高亮匹配；
- 终端持续输出时更新结果，但不主动改变当前结果。

搜索必须保持 `TerminalCore` 的纯 Swift 边界，不增加关闭搜索时的渲染成本，
也不得给每个 cell 或每行增加常驻字段。

## 范围

### 包含

- 当前 pane 的 scrollback 与当前活动屏幕；
- 普通文本、默认忽略大小写、输入时实时搜索；
- 中文、宽字符、emoji 与组合字符；
- 跨软折行匹配，不跨真正换行匹配；
- 结果计数、循环跳转、历史定位与两级高亮；
- 浅色、深色模式；
- 单 pane 与分屏焦点路由；
- scrollback 淘汰、窗口 reflow、备用屏切换和持续输出更新。

### 不包含

- 正则表达式、模糊搜索、整词匹配与大小写切换按钮；
- 跨 pane、跨标签或跨项目搜索；
- 替换；
- 搜索历史、重启恢复或配置项；
- 已经离开且未进入 scrollback 的备用屏内容；
- 常驻全文索引。

## 交互设计

### 打开与归属

`Command-F` 只作用于当前第一响应者所属的 `TerminalMetalView`。搜索条显示在
该 pane 右上角，并立即聚焦搜索框。

同一标签同时只显示一个搜索条。在另一 pane 聚焦后再次按 `Command-F`：

1. 关闭旧 pane 的搜索条并清除旧高亮；
2. 在新 pane 打开搜索条；
3. 焦点进入新搜索框。

搜索条已打开时再次按 `Command-F`，不重建搜索状态，而是聚焦并全选现有查询。

### 输入与跳转

- 空查询不扫描，显示 `0 / 0`；
- 查询变化时实时搜索；
- 首个结果选择离当前视口最近的匹配；距离相同时选择较新的结果；
- `Enter` 或向下按钮跳到下一个；
- `Shift-Enter` 或向上按钮跳到上一个；
- 到边界后循环；
- 无结果时两个跳转按钮禁用；
- `Escape` 或关闭按钮退出搜索、清除高亮，并把焦点还给原 pane。

跳转历史结果只改变目标 pane 的 `scrollOffset`。结果尽量位于视口垂直中部；
靠近 scrollback 两端时夹到合法范围。其他 pane 的滚动、焦点和搜索状态不变。

### 持续输出

搜索条打开期间，新输出会更新总结果数。已有当前结果仍存在时保持其身份与
序号，不因新结果出现而自动跳转。当前结果被 scrollback 淘汰或屏幕改写后，
选择离原坐标最近的剩余结果；没有结果时显示 `0 / 0`。

## 视觉设计

### 视觉方向

- **Visual thesis**：克制的原生终端工具浮层，使用 Ink 的中性 elevated surface
  与青色 accent，不引入新的材质语言。
- **Content plan**：搜索框、`当前 / 总数`、上一个、下一个、关闭，单行排列。
- **Interaction thesis**：约 `InkDesignTokens.Motion.stateDuration` 的淡入淡出，
  系统按钮 hover/按压反馈；终端内容不平移、不缩放。

### 搜索条

搜索条使用 `NSVisualEffectView` 的 `.popover` 材质与 `.withinWindow` 混合，放在
`TerminalPaneContainerView` 内部、`TerminalMetalView` 之上：

- top 与 trailing 使用 `InkDesignTokens.Spacing.xs`；
- 圆角使用 `InkDesignTokens.Radius.control`；
- 材质之上的边界采用 separator；
- 文本使用系统 body/label token；
- 图标使用 SF Symbols 的上、下、关闭符号；
- 不改变 `TerminalMetalView` frame，因此打开或关闭搜索不会触发 PTY resize。

### 结果高亮

终端 palette 增加搜索专用的动态颜色快照：

- 普通结果：低透明度 accent 背景，保留 ANSI 前景色可读性；
- 当前结果：更强的 accent 背景与一像素 accent 底边；
- 用户手动选区优先于搜索高亮；
- 光标与现有终端语义维持当前优先级。

高亮颜色分别在浅色、深色外观下真机校准，不直接在业务组件中散落 RGB 值。

## 架构

```text
MainWindowController
  └─ TerminalWorkspaceViewController
       └─ TerminalPaneContainerView
            ├─ TerminalMetalView
            └─ TerminalSearchBarView

TerminalSearchController（InkShell / 主线程）
  ├─ 管理当前 pane、查询、结果序号与 UI
  ├─ 调用 TerminalCore 搜索器
  └─ 把当前视口高亮与目标滚动位置交给 TerminalMetalView

TerminalCore
  └─ TerminalSearchEngine（纯 Swift）
       └─ 查询 Terminal 的 scrollback + 当前 grid，返回 cell 坐标
```

### TerminalCore 搜索模型

新增值类型：

```swift
public struct TerminalSearchMatch: Sendable, Equatable {
    public let range: SelectionRange
}
```

搜索器接收 `Terminal` 的只读行数据与查询文本，返回从旧到新排序的匹配。
`TerminalSearchMatch` 不保存 `String`，只保存绝对行与 cell 列坐标。

搜索器按 `wrapped` 元数据把物理行拼成逻辑行。构造临时搜索文本时同时维护
字符串索引到 `TextPosition` 的映射，因此：

- ANSI 属性不会进入查询文本；
- 宽字符尾格不会重复；
- 组合簇仍映射到其所属 cell；
- 跨软折行的匹配能返回跨物理行的 `SelectionRange`；
- 真正换行形成新的逻辑行，查询不跨越它。

大小写忽略使用 Swift Unicode 感知的 case-insensitive 查找，不自行维护 ASCII
小写副本。查询与临时逻辑行字符串只在搜索路径存在，不进入 grid 或 renderer
热路径。同一逻辑行中的重叠候选按最早起点优先，以非重叠范围返回。

### 搜索状态与增量更新

`TerminalSearchController` 为打开搜索的 pane 持有瞬态缓存：

- 当前查询；
- scrollback 匹配；
- 当前 grid 匹配；
- 合并后的有序结果；
- 当前结果身份与索引；
- 上次观察到的 scrollback 追加/淘汰状态与 reflow 代次。

首次查询或查询变化时执行全量扫描。终端输出更新时：

1. 同一主队列周期内的多次 `onUpdate` 合并成一次刷新，不使用固定延时；
2. 已冻结的旧 scrollback 行不重扫；
3. 扫描新进入 scrollback 的行；
4. 当前 grid 行数小，整屏重扫，以覆盖光标寻址造成的任意屏幕改写；
5. scrollback 淘汰时平移或删除受影响坐标；
6. reflow 或无法证明增量安全的结构变化触发全量重扫。

为支持增量判断，可以在 scrollback/terminal 上增加缓冲级计数器或代次，但禁止
给每行或每个 cell 增加常驻字段。计数更新按行或按一次 resize 发生，不进入每格
渲染循环。

### Shell 与 pane 生命周期

`TerminalWorkspaceViewController` 负责搜索条属于哪个 pane：

- 打开新搜索前关闭旧搜索；
- pane 关闭、标签切换、设置页打开或 shell 退出时清理搜索；
- 工作区因分屏重建视图时，搜索状态不跨重建恢复，避免坐标与 view 失配；
- `Command-F` 的菜单 action 通过当前 first responder 解析目标 pane；
- 搜索框处理 Enter、Shift-Enter 与 Escape，不把这些按键写入 PTY。

### TerminalMetalView 与 renderer

`TerminalMetalView` 接收搜索结果和当前结果，负责：

- 根据 `scrollOffset` 只整理当前可见行的匹配区间；
- 跳转时更新自身 `scrollOffset`；
- 搜索变化、滚动、resize 或输出时刷新可见高亮；
- 关闭搜索时清空所有搜索渲染状态。

renderer 不接收全部历史匹配。它只接收当前可见行的有序区间，每行解析一次，
cell 循环按列顺序推进区间游标，避免每个 cell 遍历全部结果。搜索关闭时传入空
状态并走原有渲染分支，不做额外查找或分配。

现有每帧一次 draw call 纪律保持不变。若当前结果需要边界效果，必须通过现有
instance 数据和同一 fragment pass 表达，不新增 draw call。

## 数据变化与一致性

### Scrollback 淘汰

搜索结果坐标相对当前可寻址历史。缓冲淘汰头部行时，缓存删除被淘汰结果并调整
剩余行坐标。当前结果被淘汰时按原位置选择最近结果。

### Reflow

列数变化会改变物理行、软折行与 cell 坐标。reflow 完成后使搜索缓存失效并执行
全量重扫。搜索条保持打开，查询保持不变，当前结果按文本位置就近重新选择。

打开或关闭搜索条本身不改变终端尺寸，不会触发 reflow。

### 备用屏

搜索范围始终是既有 scrollback 加当前活动 grid。进入备用屏后搜索当前备用屏；
离开后备用屏内容随现有终端语义消失，不伪造历史。切换屏幕使 grid 匹配重扫。

## 性能与内存边界

- 搜索关闭：不扫描、不保留结果、renderer 无额外每格判断；
- 搜索打开：允许按匹配数量增长的瞬态结果数组；
- 不增加 per-cell、per-line 常驻存储；
- 不建立每个 pane 常驻全文索引；
- 查询变化允许扫描 10 万行，但不得物化整个终端为一份常驻大字符串；
- 按逻辑行构造临时字符串与坐标映射，处理完即释放；
- 持续输出使用合并刷新与 scrollback 增量扫描，避免每个 PTY 数据块全量扫描；
- renderer 只处理可见匹配，保持一次 draw call。

性能验收记录 Release 构建下 10 万行常见宽度的首次搜索耗时、结果缓存增量和
持续输出采样。若搜索逻辑出现在关闭搜索后的 Time Profiler 热路径，视为失败。

## 错误与空状态

- 空查询：`0 / 0`，无扫描；
- 无匹配：`0 / 0`，上一个/下一个禁用；
- 查询或终端变化导致当前索引越界：先重建结果，再夹取或选择最近结果；
- pane/session 已失效：关闭搜索，不访问旧 terminal/provider；
- 搜索过程中发生 reflow：丢弃旧代次结果，以新快照重扫；
- 搜索不会阻止 PTY 输出、键盘输入或 pane 关闭。

## 测试计划

### TerminalCore

- ASCII 与默认忽略大小写；
- 中文、宽字符尾格、emoji、ZWJ、组合字符；
- 同行多结果与重叠候选的明确非重叠顺序；
- 跨软折行匹配与不跨硬换行；
- scrollback + grid 的全局顺序；
- 10 万行、环形淘汰、追加、grid 改写与 reflow；
- 空查询和无结果不产生匹配；
- 搜索模型不引入 AppKit/Metal。

### InkTerminalView

- 只把当前可见匹配交给 renderer；
- 普通结果、当前结果、用户选区的优先级；
- 上下跳转更新 `scrollOffset` 并居中/夹取；
- 手动滚动后再次跳转；
- 清理搜索状态后恢复原渲染路径；
- 一次 draw call 约束不变。

### InkShell

- `Command-F` 只打开焦点 pane；
- 同标签只有一个搜索条；
- 再按 `Command-F` 全选查询；
- Enter、Shift-Enter、按钮、Escape 与关闭按钮；
- `当前 / 总数` 和按钮禁用状态；
- 标签切换、pane 关闭、shell 退出、设置页与工作区重建时清理；
- 持续输出更新总数但保持当前结果。

### 真机与性能

- 浅色、深色模式检查搜索条与两级背景高亮；
- 单 pane、左右分屏、上下分屏和四 pane；
- 打开搜索条前后 grid size 不变；
- 历史跳转、高亮可读性、ANSI 前景色与用户选区；
- 10 万行首次搜索耗时与内存；
- 四 pane 中仅一个搜索开启时的 Time Profiler；
- `swift test` 全绿，`swift build -c release` 零警告。

## 验收结论

功能完成时，用户能在当前聚焦 pane 内用 `Command-F` 搜索全部已显示历史，看到
准确的结果总数和当前位置，通过按钮或键盘循环跳转，并得到与 Ink UI 协调的
高亮。其他 pane 不受搜索、滚动或焦点变化影响，关闭搜索后没有常驻搜索成本。
