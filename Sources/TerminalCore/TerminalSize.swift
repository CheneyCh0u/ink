/// 终端网格尺寸（列 × 行）。
///
/// 约束到最小 1×1：0 尺寸的 grid 没有意义，且会让下游的除法和缓冲区
/// 分配全部带上边界判断。
public struct TerminalSize: Sendable, Equatable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}
