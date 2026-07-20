# 终端分屏容器重构设计

关联 Issue：[GitHub #29](https://github.com/CheneyCh0u/ink/issues/29)

## 背景

当前实现使用多子项 `NSSplitView` 展示同方向 pane。布局树、PTY 和快捷键都能正确创建与关闭 pane，但 `NSSplitView` 在后续布局周期中会把第一个 pane 扩到整个区域，其余 pane 压成 0。真实窗口的 divider 落在容器边缘，`Command-W` 仍能逐个关闭隐藏 pane。

回归测试已经复现相同过程：第一次布局后所有 pane frame 正常，强制 split view 再布局一次后，除第一个 pane 外的高度全部归零。调整 `layout()` 调用顺序、使用 `setPosition(_:ofDividerAt:)` 和覆盖 `adjustSubviews()` 都不能稳定保留多子项尺寸。

## 目标与范围

本次只替换当前标签的分屏视图容器。以下部分保持不变：

- `PaneLayout` 的多子项分组、权重和四方向插入规则。
- `TerminalTab` 的 pane 集合与焦点管理。
- PTY 创建、目录继承、退出和资源释放。
- `Command-D` 组合键与 `Command-W` 关闭当前 pane。
- 每个 pane 独立的 `TerminalMetalView`。

新容器需要支持横向和纵向多子项布局、嵌套分组、窗口缩放、分隔线拖动和权重回写。常用规模仍按 1 到 4 个 pane 验收，不设置固定数量上限。

## 方案取舍

采用轻量的 `NSView` 容器，自行计算子视图 frame，并绘制和命中分隔线。布局只依赖 `axis`、`weights` 和容器 bounds，不使用 `NSSplitView` 的 arranged subview 状态。

没有采用 `NSSplitViewController`。它会为每个布局分组增加控制器和 `NSSplitViewItem`，对象更多，也没有消除对 `NSSplitView` 内部布局状态的依赖。

没有继续修补当前 `NSSplitView`。三种不同初始化方式都在第二轮布局中复现尺寸归零，继续调整调用时序缺少可靠依据。

## 组件边界

`WorkspaceSplitContainerView` 是普通 `NSView`，保存以下运行态：

```swift
final class WorkspaceSplitContainerView: NSView {
    let splitID: SplitID
    let axis: PaneSplitAxis
    private(set) var weights: [Double]
    var onWeightsChange: ((SplitID, [Double]) -> Void)?
}
```

容器只管理直接子视图，不知道 `PaneID`、PTY 或终端配置。`TerminalWorkspaceViewController` 继续递归构建布局树，并把每个分组的子节点加入对应容器。方向变化时形成嵌套容器，同方向 pane 仍位于一个多子项容器中。

容器不持有模型对象。拖动完成后，它通过 `SplitID` 和归一化权重通知工作区，由工作区写回当前 `TerminalTab`。

## 布局算法

每次 `layout()` 都从权重计算 frame，不读取上一次 frame 作为布局来源：

1. 用容器轴向长度减去全部 1 pt 分隔线，得到可分配长度。
2. 权重数量必须与子视图数量一致，且每项为正数。无效输入使用等分权重，避免产生不可见 pane。
3. 前 `n - 1` 个子视图按权重计算长度，最后一个子视图吸收浮点取整余量。
4. 横向分组依次设置 `x` 与 `width`，纵向分组依次设置 `y` 与 `height`。
5. bounds 变化时重新计算全部 frame，不修改模型权重。

分配空间不足时，容器仍保持每个 pane 为正尺寸。创建分屏前的网格检查继续负责阻止不实用的新 pane。

## 分隔线与拖动

容器在 `draw(_:)` 中使用 `NSColor.separatorColor` 绘制 1 pt 分隔线。视觉宽度不参与额外布局，分隔线位置由相邻 pane frame 决定。

每条分隔线的鼠标命中区域扩展到 7 pt。`resetCursorRects()` 为横向分组设置左右缩放光标，为纵向分组设置上下缩放光标。

拖动流程如下：

1. `mouseDown` 找到命中的 divider，记录相邻两个 pane 的起始长度和鼠标位置。
2. `mouseDragged` 只调整 divider 两侧的权重，其他 pane 权重不变。
3. 左右分组优先为每侧保留 80 pt，上下分组优先为每侧保留 48 pt。相邻两项空间不足时，实际下限降为两项总长度的一半，保证两侧都是正尺寸。
4. 每次拖动更新容器权重并触发布局，不写回 `TerminalTab`。
5. `mouseUp` 把整组权重归一化，只提交一次 `onWeightsChange`。

容器移出视图树时不需要额外注销全局事件，因为拖动使用普通 `NSResponder` 事件链。

## 性能与内存

重构不修改 `TerminalCore`、grid、scrollback 或 Metal 渲染路径。容器只在窗口布局或用户拖动时计算 frame，复杂度为当前分组的直接子视图数量。

每个分组只有一个容器视图，不为每条 divider 创建常驻视图。分隔线矩形按需计算，常用的四 pane 布局不会增加 per-cell、per-line 或每帧终端渲染开销。

## 测试与验收

测试使用普通 `NSView` 子项验证容器本身，再通过 `TerminalWorkspaceViewController` 验证真实终端视图树：

- 两个及五个纵向 pane 连续执行多轮布局后都保持可见。
- 横向和纵向容器按给定权重恢复尺寸，最后一个 pane 正确吸收余量。
- 容器缩放后保持权重比例，不把临时尺寸写回模型。
- 三子项分组拖动第一条和第二条 divider 时，只改变相邻权重。
- 拖动不能把任何 pane 压到 0，鼠标松开只提交一次归一化权重。
- 混合方向嵌套后，每个叶节点都有正宽度和正高度。
- 连续向下分屏、拖动 divider 和 `Command-W` 收拢需要在临时验证应用中再次检查。

回归测试必须强制每个分组执行至少两轮布局。只检查首次 frame 不能作为通过条件。
