/// 组合簇旁路表：带变音符 / ZWJ 序列 / 变体选择符的 cell 放不进 4 字节
/// scalar，完整码点序列存这里，cell 里存 `索引 | clusterFlag`。
///
/// 按内容去重：同一个 emoji 序列（比如 👨‍👩‍👧‍👦）在滚动历史里出现一万次也只存
/// 一份。表只增不减——去重之下增长上限是「出现过的不同簇的数量」，正常
/// 使用是几十个量级。M6 内存验收时若真成为问题再做世代回收。
public struct ClusterTable: Sendable {
    private var clusters: ContiguousArray<ContiguousArray<UInt32>> = []
    private var indexByKey: [String: UInt32] = [:]

    public init() {}

    /// 簇 → cell scalar 字段编码（含 clusterFlag）。
    public mutating func encode(_ scalars: ContiguousArray<UInt32>) -> UInt32 {
        var key = ""
        key.unicodeScalars.reserveCapacity(scalars.count)
        for s in scalars {
            key.unicodeScalars.append(Unicode.Scalar(s) ?? "\u{FFFD}")
        }
        if let existing = indexByKey[key] {
            return existing | Cell.clusterFlag
        }
        let index = UInt32(clusters.count)
        clusters.append(scalars)
        indexByKey[key] = index
        return index | Cell.clusterFlag
    }

    /// cell scalar 字段 → 完整码点序列。渲染器整形时取用。
    @inline(__always)
    public func scalars(for encoded: UInt32) -> ContiguousArray<UInt32> {
        clusters[Int(encoded & ~Cell.clusterFlag)]
    }

    public var count: Int { clusters.count }
}
