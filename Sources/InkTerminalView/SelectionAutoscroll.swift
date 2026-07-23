import CoreGraphics
import Foundation

enum SelectionAutoscrollDirection: Int {
    case towardHistory = 1
    case towardLatest = -1
}

struct SelectionAutoscrollState {
    private static let baseRowsPerSecond: CGFloat = 8
    private static let addedRowsPerCell: CGFloat = 4
    private static let maximumRowsPerSecond: CGFloat = 40
    private static let maximumRowsPerTick: CGFloat = 4
    private var remainder: CGFloat = 0
    private var direction: SelectionAutoscrollDirection?

    static func direction(
        pointerY: CGFloat,
        gridTop: CGFloat,
        gridBottom: CGFloat
    ) -> SelectionAutoscrollDirection? {
        if pointerY < gridTop { return .towardHistory }
        if pointerY >= gridBottom { return .towardLatest }
        return nil
    }

    mutating func rowsToScroll(
        pointerY: CGFloat,
        gridTop: CGFloat,
        gridBottom: CGFloat,
        cellHeight: CGFloat,
        elapsed: TimeInterval
    ) -> Int {
        guard cellHeight > 0,
              elapsed > 0,
              let nextDirection = Self.direction(
                  pointerY: pointerY,
                  gridTop: gridTop,
                  gridBottom: gridBottom
              )
        else {
            reset()
            return 0
        }
        if direction != nextDirection {
            remainder = 0
            direction = nextDirection
        }
        let overflow = nextDirection == .towardHistory
            ? gridTop - pointerY
            : pointerY - gridBottom
        let rowsPerSecond = min(
            Self.maximumRowsPerSecond,
            Self.baseRowsPerSecond
                + overflow / cellHeight * Self.addedRowsPerCell
        )
        let magnitude = min(
            Self.maximumRowsPerTick,
            rowsPerSecond * CGFloat(elapsed)
        )
        remainder += CGFloat(nextDirection.rawValue) * magnitude
        let rows = Int(remainder)
        remainder -= CGFloat(rows)
        return rows
    }

    mutating func reset() {
        remainder = 0
        direction = nil
    }
}
