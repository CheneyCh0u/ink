import simd

/// GPU 实例数据，与 Shaders.metal 的 `CellInstance` 布局严格一致。
/// 一个可见 cell 一条（宽字符尾格不发实例，首格的 2 倍宽 quad 盖住它）。
struct CellInstance {
    var gridPos: SIMD2<Float>
    var uvRect: SIMD4<Float>
    var fg: SIMD4<Float>
    var bg: SIMD4<Float>
    var flags: UInt32

    static let hasGlyph: UInt32 = 1 << 0
    static let colorGlyph: UInt32 = 1 << 1
    static let wide: UInt32 = 1 << 2
    static let underline: UInt32 = 1 << 3
    static let strikethrough: UInt32 = 1 << 4
}

/// 帧 uniform，与 Shaders.metal 的 `Uniforms` 一致。
struct Uniforms {
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var origin: SIMD2<Float>
}
