import AppKit

/// 按权重显式布局直接子视图，不依赖 NSSplitView 的内部 divider 状态。
@MainActor
final class WorkspaceSplitContainerView: NSView {
    let splitID: SplitID
    let axis: PaneSplitAxis
    private(set) var weights: [Double]

    override var isFlipped: Bool { true }

    init(splitID: SplitID, axis: PaneSplitAxis, weights: [Double]) {
        self.splitID = splitID
        self.axis = axis
        self.weights = weights
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("代码构建，不支持 nib")
    }

    func addPaneSubview(_ view: NSView) {
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = subviews.count
        guard count > 0 else { return }

        let resolvedWeights = normalizedWeights(for: count)
        weights = resolvedWeights
        let dividerTotal = CGFloat(count - 1)
        let available = max(0, axisLength - dividerTotal)
        var origin: CGFloat = 0

        for index in subviews.indices {
            let length = index == count - 1
                ? max(0, axisLength - origin)
                : available * CGFloat(resolvedWeights[index])
            setFrame(of: subviews[index], origin: origin, length: length)
            origin += length + 1
        }
    }

    private var axisLength: CGFloat {
        axis == .leftRight ? bounds.width : bounds.height
    }

    private func normalizedWeights(for count: Int) -> [Double] {
        guard weights.count == count,
              weights.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        return weights.map { $0 / total }
    }

    private func setFrame(of view: NSView, origin: CGFloat, length: CGFloat) {
        view.frame = axis == .leftRight
            ? NSRect(x: origin, y: 0, width: length, height: bounds.height)
            : NSRect(x: 0, y: origin, width: bounds.width, height: length)
    }
}
