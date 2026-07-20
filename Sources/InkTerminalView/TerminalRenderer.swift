import AppKit
import Metal
import QuartzCore
import simd
import TerminalCore
import InkDesign

// AppKit 系有同名类型，显式限定到 TerminalCore。
private typealias ColorTable = TerminalCore.ColorTable

private protocol SearchHighlightLookup {
    mutating func beginRow(_ visualRow: Int)
    mutating func kind(column: Int, isSelected: Bool) -> TerminalSearchHighlightKind
}

private struct NoSearchHighlightLookup: SearchHighlightLookup {
    @inline(__always) mutating func beginRow(_ visualRow: Int) {}
    @inline(__always) mutating func kind(
        column: Int, isSelected: Bool
    ) -> TerminalSearchHighlightKind { .none }
}

private struct SpanSearchHighlightLookup: SearchHighlightLookup {
    let spans: [TerminalSearchHighlightSpan]
    private var visualRow = 0
    private var cursor = 0

    init(spans: [TerminalSearchHighlightSpan]) {
        self.spans = spans
    }

    @inline(__always)
    mutating func beginRow(_ visualRow: Int) {
        self.visualRow = visualRow
        while cursor < spans.count, spans[cursor].visualRow < visualRow {
            cursor += 1
        }
    }

    @inline(__always)
    mutating func kind(
        column: Int, isSelected: Bool
    ) -> TerminalSearchHighlightKind {
        guard !isSelected else { return .none }
        while cursor < spans.count,
              spans[cursor].visualRow == visualRow,
              spans[cursor].columns.upperBound < column {
            cursor += 1
        }
        guard cursor < spans.count,
              spans[cursor].visualRow == visualRow,
              spans[cursor].columns.contains(column)
        else { return .none }
        return spans[cursor].isCurrent ? .current : .ordinary
    }
}

/// Metal 在驱动自己的 completion queue 上调用完成回调，不能继承
/// `TerminalRenderer` 的 MainActor 隔离。
enum MetalCommandCompletion {
    static func signal(_ semaphore: DispatchSemaphore) -> @Sendable (MTLCommandBuffer) -> Void {
        { _ in semaphore.signal() }
    }
}

/// Metal 渲染器：把 `Terminal` 的 grid 变成一次 instanced draw。
///
/// 热路径纪律（CLAUDE.md）：`buildInstances` 每帧跑满屏 cell，里面只做
/// 位运算、数组索引和字典命中；`NSColor`、`String` 分配只发生在 atlas
/// 未命中的首次栅格化里。调色板换成 LUT 数组，外观切换时整表重建。
@MainActor
final class TerminalRenderer {

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var atlas: GlyphAtlas

    // 三缓冲环：CPU 写第 N 帧时 GPU 还在读第 N-1 帧。
    private var instanceBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var bufferCapacity = 0

    // 调色板快照 → float4 LUT。0–255 索引 + 默认前景/背景 + 光标。
    private var lut = [SIMD4<Float>](repeating: .zero, count: 256)
    private var defaultFG: SIMD4<Float> = .zero
    private var defaultBG: SIMD4<Float> = .zero
    private var cursorColor: SIMD4<Float> = .zero
    private var selectionColor: SIMD4<Float> = .zero
    private var searchColor: SIMD4<Float> = .zero
    private(set) var clearColor = MTLClearColor()

    private let contentInset: CGFloat
    let scale: CGFloat
    /// 光标形状，配置系统驱动。
    var cursorStyle: TerminalCursorStyle = .block

    /// 视图坐标（point）下的 cell 尺寸，鼠标命中用。
    var cellSizePoints: CGSize {
        CGSize(width: atlas.cellWidth / scale, height: atlas.cellHeight / scale)
    }

    init?(font: NSFont, scale: CGFloat, lineHeightMultiplier: CGFloat = 1.0) {
        // swift build 不编译 .metal（只有 Xcode 构建系统会），shader 以源码
        // 进 bundle、启动时编译一次。失败原因打到 stderr，方便命令行排查。
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let shaderURL = Bundle.main.url(forResource: "Shaders", withExtension: "metal")
                ?? Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
            let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8)
        else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            FileHandle.standardError.write(Data("shader 编译失败：\(error)\n".utf8))
            return nil
        }
        guard
            let vertexFn = library.makeFunction(name: "cell_vertex"),
            let fragmentFn = library.makeFunction(name: "cell_fragment"),
            let atlas = GlyphAtlas(
                device: device, font: font, scale: scale,
                lineHeightMultiplier: lineHeightMultiplier
            )
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.atlas = atlas
        self.scale = scale
        self.contentInset = InkDesignTokens.Spacing.sm * scale
    }

    // MARK: - 调色板

    func apply(palette: InkTerminalPalette) {
        for i in 0..<16 {
            lut[i] = Self.floatColor(palette.ansi[i].rgb)
        }
        // 16–255：xterm 标准公式生成，不属于主题（docs/design-system.md）。
        for i in 16..<232 {
            let v = i - 16
            let levels: [Float] = [0, 95, 135, 175, 215, 255]
            lut[i] = SIMD4(
                levels[v / 36] / 255,
                levels[v / 6 % 6] / 255,
                levels[v % 6] / 255,
                1
            )
        }
        for i in 232..<256 {
            let g = Float((i - 232) * 10 + 8) / 255
            lut[i] = SIMD4(g, g, g, 1)
        }
        defaultFG = Self.floatColor(palette.defaultForeground.rgb)
        defaultBG = Self.floatColor(palette.defaultBackground.rgb)
        cursorColor = Self.floatColor(palette.cursor.rgb)
        selectionColor = Self.floatColor(palette.selection.rgb)
        searchColor = Self.floatColor(palette.searchHighlight.rgb)
        clearColor = MTLClearColor(
            red: Double(defaultBG.x), green: Double(defaultBG.y),
            blue: Double(defaultBG.z), alpha: 1
        )
    }

    private static func floatColor(_ rgb: UInt32) -> SIMD4<Float> {
        SIMD4(
            Float((rgb >> 16) & 0xFF) / 255,
            Float((rgb >> 8) & 0xFF) / 255,
            Float(rgb & 0xFF) / 255,
            1
        )
    }

    // MARK: - 网格度量

    /// 视图尺寸（物理像素）能容纳的列 × 行。
    func gridSize(forPixelSize size: CGSize) -> TerminalSize {
        TerminalSize(
            columns: Int((size.width - contentInset * 2) / atlas.cellWidth),
            rows: Int((size.height - contentInset * 2) / atlas.cellHeight)
        )
    }

    /// 指定网格完整可见时，终端视图在 point 坐标下需要的最小尺寸。
    func viewportSize(columns: Int, rows: Int) -> CGSize {
        CGSize(
            width: (CGFloat(columns) * atlas.cellWidth + contentInset * 2 + 1) / scale,
            height: (CGFloat(rows) * atlas.cellHeight + contentInset * 2 + 1) / scale
        )
    }

    // MARK: - 渲染

    func render(
        terminal: Terminal,
        into layer: CAMetalLayer,
        cursorOn: Bool,
        scrollOffset: Int = 0,
        selection: SelectionRange? = nil,
        searchHighlights: [TerminalSearchHighlightSpan] = [],
        preedit: String? = nil
    ) {
        let grid = terminal.grid
        // 预编辑最长占一行，多留一行的量。
        let maxInstances = grid.size.columns * (grid.size.rows + 1) + 2
        ensureBuffers(capacity: maxInstances)

        inflight.wait()
        bufferIndex = (bufferIndex + 1) % instanceBuffers.count
        let buffer = instanceBuffers[bufferIndex]

        var count = buildInstances(
            terminal: terminal, cursorOn: cursorOn && preedit == nil,
            scrollOffset: scrollOffset, selection: selection?.normalized,
            searchHighlights: searchHighlights,
            into: buffer
        )
        if let preedit, !preedit.isEmpty, scrollOffset == 0 {
            count = appendPreedit(preedit, terminal: terminal, into: buffer, from: count)
        }

        guard
            let drawable = layer.nextDrawable(),
            let commands = commandQueue.makeCommandBuffer()
        else {
            inflight.signal()
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor

        var uniforms = Uniforms(
            viewportSize: SIMD2(Float(layer.drawableSize.width), Float(layer.drawableSize.height)),
            cellSize: SIMD2(Float(atlas.cellWidth), Float(atlas.cellHeight)),
            origin: SIMD2(Float(contentInset), Float(contentInset)),
            cursorColor: cursorColor,
            searchEdgeColor: searchColor
        )

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal()
            return
        }
        if count > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentTexture(atlas.monoTexture, index: 0)
            // 彩色图集未分配（没出现过 emoji）时随便绑一个占位，
            // colorGlyph flag 不会置起，不会被采样。
            encoder.setFragmentTexture(atlas.colorTexture ?? atlas.monoTexture, index: 1)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count
            )
        }
        encoder.endEncoding()

        commands.addCompletedHandler(MetalCommandCompletion.signal(inflight))
        commands.present(drawable)
        commands.commit()
    }

    private func ensureBuffers(capacity: Int) {
        guard capacity > bufferCapacity else { return }
        let bytes = capacity * MemoryLayout<CellInstance>.stride
        instanceBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        bufferCapacity = capacity
        bufferIndex = 0
    }

    // MARK: - 实例构建

    /// 可见区 cell → instance buffer。返回实例数。
    /// 可见区 = scrollback 尾部 `scrollOffset` 行 + grid 顶部若干行。
    /// 空白且默认背景的 cell 不发实例（clear color 已经盖住），
    /// 常见画面里这能砍掉七八成实例。
    private func buildInstances(
        terminal: Terminal, cursorOn: Bool,
        scrollOffset: Int, selection: SelectionRange?,
        searchHighlights: [TerminalSearchHighlightSpan],
        into buffer: MTLBuffer
    ) -> Int {
        if searchHighlights.isEmpty {
            var lookup = NoSearchHighlightLookup()
            return buildInstances(
                terminal: terminal,
                cursorOn: cursorOn,
                scrollOffset: scrollOffset,
                selection: selection,
                searchLookup: &lookup,
                into: buffer
            )
        }
        var lookup = SpanSearchHighlightLookup(spans: searchHighlights)
        return buildInstances(
            terminal: terminal,
            cursorOn: cursorOn,
            scrollOffset: scrollOffset,
            selection: selection,
            searchLookup: &lookup,
            into: buffer
        )
    }

    /// 泛型 lookup 让 Release 编译器为无搜索状态生成不含搜索判断的专用循环。
    private func buildInstances<Lookup: SearchHighlightLookup>(
        terminal: Terminal, cursorOn: Bool,
        scrollOffset: Int, selection: SelectionRange?,
        searchLookup: inout Lookup,
        into buffer: MTLBuffer
    ) -> Int {
        let grid = terminal.grid
        let cols = grid.size.columns
        let rows = grid.size.rows
        let sbCount = terminal.scrollback.count
        let offset = min(scrollOffset, sbCount)
        let output = buffer.contents().bindMemory(to: CellInstance.self, capacity: bufferCapacity)
        var count = 0

        let cursorRow = grid.cursorRow
        let cursorCol = grid.cursorCol
        // 翻看历史时不画光标——它属于屏上区域，回到底部才有意义。
        let drawCursor = cursorOn && terminal.modes.showCursor && offset == 0

        for visualRow in 0..<rows {
            searchLookup.beginRow(visualRow)
            let absLine = sbCount - offset + visualRow
            let fromScrollback = visualRow < offset
            let gridRow = visualRow - offset
            let sbLine: ScrollbackLine? = fromScrollback ? terminal.scrollback[absLine] : nil

            for col in 0..<cols {
                let cell: Cell
                if let sbLine {
                    cell = col < sbLine.count ? sbLine.cell(at: col) : .blank
                } else {
                    cell = grid[gridRow, col]
                }
                let attr = cell.attr

                if attr & Cell.Attr.wideTrailing != 0 { continue } // 首格的宽 quad 盖住

                let isCursorCell = drawCursor && gridRow == cursorRow
                    && (col == cursorCol || (col == cursorCol - 1 && attr & Cell.Attr.wideLeading != 0))
                let isSelected = selection?.contains(line: absLine, column: col) ?? false
                let searchKind = searchLookup.kind(column: col, isSelected: isSelected)

                var (fg, bg) = resolve(attr: attr, colorTable: terminal.colorTable)
                switch searchKind {
                case .none:
                    break
                case .ordinary:
                    bg = Self.blend(bg, searchColor, alpha: 0.22)
                case .current:
                    bg = Self.blend(bg, searchColor, alpha: 0.42)
                }
                if isSelected {
                    bg = selectionColor
                }
                // 块光标反色整格；bar / underline 保持原色，flag 交给
                // fragment 画细条。
                if isCursorCell, cursorStyle == .block {
                    bg = cursorColor
                    fg = defaultBG
                }

                let hasGlyph = !(cell.scalar == 0x20 && !cell.isCluster)
                let decorations = attr & (Cell.Attr.underline | Cell.Attr.strikethrough)

                // 纯空白 + 默认背景 + 非光标非选中：不发实例。
                if !hasGlyph, decorations == 0, !isCursorCell, !isSelected,
                   searchKind == .none,
                   Cell.Attr.background(of: attr) == Cell.Attr.colorDefault,
                   attr & Cell.Attr.inverse == 0 {
                    continue
                }

                var flags: UInt32 = 0
                var uv = SIMD4<Float>.zero
                if attr & Cell.Attr.wideLeading != 0 { flags |= CellInstance.wide }
                if decorations & Cell.Attr.underline != 0 { flags |= CellInstance.underline }
                if decorations & Cell.Attr.strikethrough != 0 { flags |= CellInstance.strikethrough }
                if isCursorCell {
                    if cursorStyle == .bar { flags |= CellInstance.cursorBar }
                    if cursorStyle == .underline { flags |= CellInstance.cursorUnderline }
                }
                if searchKind == .current { flags |= CellInstance.currentSearchMatch }

                if hasGlyph {
                    let text = glyphText(for: cell, clusterTable: terminal.clusterTable)
                    if let entry = atlas.entry(
                        for: text,
                        bold: attr & Cell.Attr.bold != 0,
                        italic: attr & Cell.Attr.italic != 0
                    ) {
                        flags |= CellInstance.hasGlyph
                        if entry.isColor { flags |= CellInstance.colorGlyph }
                        uv = entry.uvRect
                        // 窄字形只采样槽位左半，避免把邻座采进来。
                        if flags & CellInstance.wide == 0 { uv.z /= 2 }
                    }
                }

                output[count] = CellInstance(
                    gridPos: SIMD2(Float(col), Float(visualRow)),
                    uvRect: uv, fg: fg, bg: bg, flags: flags
                )
                count += 1
            }
        }
        return count
    }

    private static func blend(
        _ background: SIMD4<Float>, _ accent: SIMD4<Float>, alpha: Float
    ) -> SIMD4<Float> {
        SIMD4(
            background.x + (accent.x - background.x) * alpha,
            background.y + (accent.y - background.y) * alpha,
            background.z + (accent.z - background.z) * alpha,
            1
        )
    }

    // MARK: - 预编辑（输入法 marked text）

    /// 拼音预编辑覆盖在光标行上：下划线样式 + 末尾块光标。
    /// 只画不改 grid——预编辑是 UI 状态，提交（insertText）才进终端。
    private func appendPreedit(
        _ text: String, terminal: Terminal, into buffer: MTLBuffer, from start: Int
    ) -> Int {
        let grid = terminal.grid
        let cols = grid.size.columns
        let output = buffer.contents().bindMemory(to: CellInstance.self, capacity: bufferCapacity)
        var count = start
        var col = grid.cursorCol
        let row = grid.cursorRow

        for character in text {
            guard col < cols, count < bufferCapacity - 1 else { break }
            let width = CharWidth.width(of: character.unicodeScalars.first?.value ?? 0x20)
            var flags = CellInstance.underline
            if width == 2 { flags |= CellInstance.wide }
            var uv = SIMD4<Float>.zero
            if let entry = atlas.entry(for: String(character), bold: false, italic: false) {
                flags |= CellInstance.hasGlyph
                if entry.isColor { flags |= CellInstance.colorGlyph }
                uv = entry.uvRect
                if width != 2 { uv.z /= 2 }
            }
            output[count] = CellInstance(
                gridPos: SIMD2(Float(col), Float(row)),
                uvRect: uv, fg: defaultFG, bg: defaultBG, flags: flags
            )
            count += 1
            col += max(1, width)
        }
        // 预编辑末尾的插入点。
        if col < cols, count < bufferCapacity {
            output[count] = CellInstance(
                gridPos: SIMD2(Float(col), Float(row)),
                uvRect: .zero, fg: defaultBG, bg: cursorColor, flags: 0
            )
            count += 1
        }
        return count
    }

    /// 预编辑占用的显示宽度（列数），候选窗定位用。
    func preeditColumns(_ text: String) -> Int {
        text.reduce(0) { $0 + max(1, CharWidth.width(of: $1.unicodeScalars.first?.value ?? 0x20)) }
    }

    private func glyphText(for cell: Cell, clusterTable: ClusterTable) -> String {
        if cell.isCluster {
            var text = ""
            for scalar in clusterTable.scalars(for: cell.scalar) {
                text.unicodeScalars.append(Unicode.Scalar(scalar) ?? "\u{FFFD}")
            }
            return text
        }
        return String(Unicode.Scalar(cell.scalar) ?? "\u{FFFD}")
    }

    private func resolve(attr: UInt32, colorTable: ColorTable) -> (SIMD4<Float>, SIMD4<Float>) {
        var fgIdx = Cell.Attr.foreground(of: attr)
        let bgIdx = Cell.Attr.background(of: attr)

        // 经典行为：粗体把 0–7 提亮到 8–15。
        if attr & Cell.Attr.bold != 0, fgIdx < 8 { fgIdx += 8 }

        var fg = color(at: fgIdx, isForeground: true, colorTable: colorTable)
        var bg = color(at: bgIdx, isForeground: false, colorTable: colorTable)

        if attr & Cell.Attr.faint != 0 {
            fg = simd_mix(fg, bg, SIMD4(repeating: 0.45))
        }
        if attr & Cell.Attr.inverse != 0 {
            swap(&fg, &bg)
        }
        if attr & Cell.Attr.hidden != 0 {
            fg = bg
        }
        return (fg, bg)
    }

    @inline(__always)
    private func color(at index: UInt32, isForeground: Bool, colorTable: ColorTable) -> SIMD4<Float> {
        if index < 256 { return lut[Int(index)] }
        if index == Cell.Attr.colorDefault { return isForeground ? defaultFG : defaultBG }
        return Self.floatColor(colorTable.rgb(for: index))
    }
}
