import AppKit

@MainActor
protocol WorkspaceSplitMinimumSizing: AnyObject {
    var minimumSplitSize: NSSize { get }
}

/// 按权重显式布局直接子视图，不依赖 NSSplitView 的内部 divider 状态。
@MainActor
final class WorkspaceSplitContainerView: NSView, WorkspaceSplitMinimumSizing {
    static let dividerThickness: CGFloat = 1

    private struct DividerDrag {
        let index: Int
        let startCoordinate: CGFloat
        let firstLength: CGFloat
        let secondLength: CGFloat
        let firstMinimumLength: CGFloat
        let secondMinimumLength: CGFloat
    }

    let splitID: SplitID
    let axis: PaneSplitAxis
    private(set) var weights: [Double]
    var onWeightsChange: ((SplitID, [Double]) -> Void)?

    private var drag: DividerDrag?

    override var isFlipped: Bool { true }

    var minimumSplitSize: NSSize {
        guard !subviews.isEmpty else { return Self.fallbackMinimumSize }
        let childSizes = subviews.map(Self.minimumSize(of:))
        let dividerTotal = Self.dividerThickness * CGFloat(max(0, childSizes.count - 1))
        return switch axis {
        case .leftRight:
            NSSize(
                width: childSizes.reduce(dividerTotal) { $0 + $1.width },
                height: childSizes.map(\.height).max() ?? 0
            )
        case .topBottom:
            NSSize(
                width: childSizes.map(\.width).max() ?? 0,
                height: childSizes.reduce(dividerTotal) { $0 + $1.height }
            )
        }
    }

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
        let dividerTotal = Self.dividerThickness * CGFloat(count - 1)
        let available = max(0, axisLength - dividerTotal)
        var origin: CGFloat = 0

        for index in subviews.indices {
            let length = index == count - 1
                ? max(0, axisLength - origin)
                : available * CGFloat(resolvedWeights[index])
            setFrame(of: subviews[index], origin: origin, length: length)
            origin += length + Self.dividerThickness
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        for rect in dividerRects where rect.intersects(dirtyRect) {
            rect.fill()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor = axis == .leftRight ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
        for rect in dividerRects {
            addCursorRect(dividerHitRect(for: rect), cursor: cursor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        if dividerHitIndex(at: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    @discardableResult
    func beginDividerDrag(at point: NSPoint) -> Bool {
        layoutSubtreeIfNeeded()
        guard let index = dividerHitIndex(at: point) else { return false }
        drag = DividerDrag(
            index: index,
            startCoordinate: axisCoordinate(of: point),
            firstLength: childLength(at: index),
            secondLength: childLength(at: index + 1),
            firstMinimumLength: minimumAxisLength(of: subviews[index]),
            secondMinimumLength: minimumAxisLength(of: subviews[index + 1])
        )
        return true
    }

    func updateDividerDrag(to point: NSPoint) {
        guard let drag else { return }
        let delta = axisCoordinate(of: point) - drag.startCoordinate
        let pairLength = drag.firstLength + drag.secondLength
        guard pairLength > 0 else { return }

        let minimumTotal = drag.firstMinimumLength + drag.secondMinimumLength
        let compression = minimumTotal > pairLength ? pairLength / minimumTotal : 1
        let firstMinimum = drag.firstMinimumLength * compression
        let secondMinimum = drag.secondMinimumLength * compression
        let firstLength = min(
            pairLength - secondMinimum,
            max(firstMinimum, drag.firstLength + delta)
        )
        let pairWeight = weights[drag.index] + weights[drag.index + 1]
        weights[drag.index] = pairWeight * Double(firstLength / pairLength)
        weights[drag.index + 1] = pairWeight - weights[drag.index]
        needsLayout = true
    }

    func endDividerDrag() {
        guard drag != nil else { return }
        drag = nil
        let total = weights.reduce(0, +)
        guard total.isFinite, total > 0 else { return }
        weights = weights.map { $0 / total }
        onWeightsChange?(splitID, weights)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !beginDividerDrag(at: point) {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else {
            super.mouseDragged(with: event)
            return
        }
        updateDividerDrag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else {
            super.mouseUp(with: event)
            return
        }
        endDividerDrag()
    }

    private var axisLength: CGFloat {
        axis == .leftRight ? bounds.width : bounds.height
    }

    private var dividerRects: [NSRect] {
        guard subviews.count > 1 else { return [] }
        return subviews.dropLast().map { child in
            axis == .leftRight
                ? NSRect(
                    x: child.frame.maxX, y: 0,
                    width: Self.dividerThickness, height: bounds.height
                )
                : NSRect(
                    x: 0, y: child.frame.maxY,
                    width: bounds.width, height: Self.dividerThickness
                )
        }
    }

    private func dividerHitRect(for rect: NSRect) -> NSRect {
        axis == .leftRight
            ? rect.insetBy(dx: -3, dy: 0)
            : rect.insetBy(dx: 0, dy: -3)
    }

    private func dividerHitIndex(at point: NSPoint) -> Int? {
        dividerRects.firstIndex { dividerHitRect(for: $0).contains(point) }
    }

    private func axisCoordinate(of point: NSPoint) -> CGFloat {
        axis == .leftRight ? point.x : point.y
    }

    private func childLength(at index: Int) -> CGFloat {
        axis == .leftRight ? subviews[index].frame.width : subviews[index].frame.height
    }

    private func minimumAxisLength(of view: NSView) -> CGFloat {
        let size = Self.minimumSize(of: view)
        return axis == .leftRight ? size.width : size.height
    }

    private static let fallbackMinimumSize = NSSize(width: 80, height: 48)

    private static func minimumSize(of view: NSView) -> NSSize {
        (view as? WorkspaceSplitMinimumSizing)?.minimumSplitSize
            ?? fallbackMinimumSize
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
