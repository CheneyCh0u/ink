// 终端网格着色器：每 cell 一个实例，整屏一次 instanced draw。
// 背景与字形在同一实例里合成（fragment 里 glyph alpha 混合 bg），
// 不需要单独的背景 pass——这就是"每帧一次 draw call"的实现方式。
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewportSize; // 像素
    float2 cellSize;     // 像素
    float2 origin;       // 内容区左上内边距，像素
};

// 与 CellInstance.swift 的内存布局严格一致。
struct CellInstance {
    float2 gridPos;  // 列、行（格坐标）
    float4 uvRect;   // atlas 归一化 UV：x y w h
    float4 fg;
    float4 bg;
    uint   flags;    // 位定义见 CellInstance.swift
};

constant uint FLAG_HAS_GLYPH   = 1 << 0;
constant uint FLAG_COLOR_GLYPH = 1 << 1;
constant uint FLAG_WIDE        = 1 << 2;
constant uint FLAG_UNDERLINE   = 1 << 3;
constant uint FLAG_STRIKE      = 1 << 4;

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float2 cellUV;   // cell 内 0-1，画下划线/删除线用
    float4 fg;
    float4 bg;
    uint   flags [[flat]];
};

vertex VSOut cell_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms &u [[buffer(0)]],
    const device CellInstance *instances [[buffer(1)]]
) {
    constexpr float2 corners[6] = {
        {0, 0}, {1, 0}, {0, 1},
        {0, 1}, {1, 0}, {1, 1},
    };
    CellInstance inst = instances[iid];
    float2 corner = corners[vid];

    float widthCells = (inst.flags & FLAG_WIDE) ? 2.0 : 1.0;
    float2 sizePx = float2(u.cellSize.x * widthCells, u.cellSize.y);
    float2 px = u.origin + inst.gridPos * u.cellSize + corner * sizePx;

    VSOut out;
    out.position = float4(
        px.x / u.viewportSize.x * 2.0 - 1.0,
        1.0 - px.y / u.viewportSize.y * 2.0,
        0.0, 1.0
    );
    out.uv = inst.uvRect.xy + corner * inst.uvRect.zw;
    out.cellUV = corner;
    out.fg = inst.fg;
    out.bg = inst.bg;
    out.flags = inst.flags;
    return out;
}

fragment float4 cell_fragment(
    VSOut in [[stage_in]],
    texture2d<float> monoAtlas [[texture(0)]],
    texture2d<float> colorAtlas [[texture(1)]]
) {
    // 字形按物理像素 1:1 栅格化，nearest 采样保证不糊。
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);

    float4 color = in.bg;
    if (in.flags & FLAG_HAS_GLYPH) {
        if (in.flags & FLAG_COLOR_GLYPH) {
            float4 g = colorAtlas.sample(s, in.uv); // emoji：预乘 alpha
            color = float4(g.rgb + in.bg.rgb * (1.0 - g.a), 1.0);
        } else {
            float a = monoAtlas.sample(s, in.uv).r;
            color = float4(mix(in.bg.rgb, in.fg.rgb, a), 1.0);
        }
    }
    if (in.flags & FLAG_UNDERLINE) {
        if (in.cellUV.y > 0.92) { color = float4(in.fg.rgb, 1.0); }
    }
    if (in.flags & FLAG_STRIKE) {
        if (in.cellUV.y > 0.52 && in.cellUV.y < 0.58) { color = float4(in.fg.rgb, 1.0); }
    }
    return color;
}
