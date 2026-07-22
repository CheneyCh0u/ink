// 内存基准：端到端（字节流 → Parser → Terminal → scrollback）灌行，
// 读进程 phys_footprint 差值。验收指标见 docs/tech-stack.md：
// 10 万行 scrollback < 200MB。
//
// 用法：swift run -c release ink-bench

import Darwin
import Foundation
import TerminalCore

func footprintBytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

func mb(_ bytes: Int) -> String {
    String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
}

enum LinkProfile: String {
    case plain
    case sparseOSC8 = "sparse-osc8"
    case denseOSC8 = "dense-osc8"
    case alternatingOSC8 = "alternating-osc8"
    case denseUniqueOSC8 = "dense-unique-osc8"
    case fragmentedOSC8 = "fragmented-osc8"
}

enum CommandProfile: String {
    case plain = "command-plain"
    case status = "command-status"
}

if let linkProfile = CommandLine.arguments.dropFirst().first
    .flatMap(LinkProfile.init(rawValue:)) {
    let profileLineCount = 1_000_000
    let visibleText = String(repeating: "x", count: 80)
    let plainBytes = Array("\(visibleText)\r\n".utf8)
    var parser = Parser()
    var terminal = Terminal(
        size: TerminalSize(columns: 120, rows: 50),
        scrollbackCapacity: 100_000
    )
    var totalBytes = 0
    let before = footprintBytes()
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for line in 0..<profileLineCount {
            let emitsLink: Bool
            switch linkProfile {
            case .plain:
                emitsLink = false
            case .sparseOSC8:
                emitsLink = line % 1_000 == 0
            case .denseOSC8, .denseUniqueOSC8, .fragmentedOSC8:
                emitsLink = true
            case .alternatingOSC8:
                emitsLink = line.isMultiple(of: 2)
            }
            if emitsLink {
                let target: String
                switch linkProfile {
                case .denseOSC8, .alternatingOSC8:
                    target = "https://example.test/dense"
                case .sparseOSC8, .denseUniqueOSC8:
                    target = String(format: "https://example.test/%08d", line)
                case .fragmentedOSC8:
                    target = line.isMultiple(of: 2)
                        ? "https://example.test/a"
                        : "https://example.test/b"
                case .plain:
                    preconditionFailure("plain profile 不应生成链接")
                }
                let linkedText = linkProfile == .fragmentedOSC8 ? "x" : visibleText
                let terminator = linkProfile == .fragmentedOSC8 ? "" : "\r\n"
                let bytes = Array(
                    "\u{1B}]8;;\(target)\u{07}\(linkedText)\u{1B}]8;;\u{07}\(terminator)".utf8
                )
                totalBytes += bytes.count
                parser.feed(bytes, handler: &terminal)
            } else {
                totalBytes += plainBytes.count
                parser.feed(plainBytes, handler: &terminal)
            }
        }
    }
    let after = footprintBytes()
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let throughput = Double(totalBytes) / seconds / 1024 / 1024
    print("链接旁路 profile: \(linkProfile.rawValue)")
    print("  行数 \(profileLineCount)  字节 \(totalBytes)")
    print("  耗时 \(elapsed)")
    print("  吞吐 \(String(format: "%.1f", throughput)) MB/s")
    print("  footprint 增量 \(mb(after - before))")
    print("  scrollback \(terminal.scrollback.count) 行")
    exit(EXIT_SUCCESS)
}

if let commandProfile = CommandLine.arguments.dropFirst().first
    .flatMap(CommandProfile.init(rawValue:)) {
    let profileLineCount = 1_000_000
    let visibleText = String(repeating: "x", count: 52)
    let plainBytes = Array(
        "\(visibleText)\(String(repeating: " ", count: 26))\r\n".utf8
    )
    let statusBytes = Array((
        "\u{1B}]133;B\u{07}x"
            + "\u{1B}]133;C\u{07}\(String(repeating: "x", count: 51))"
            + "\u{1B}]133;D;0\u{07}\r\n"
    ).utf8)
    precondition(plainBytes.count == statusBytes.count)
    let bytes = commandProfile == .status ? statusBytes : plainBytes
    var parser = Parser()
    var terminal = Terminal(
        size: TerminalSize(columns: 120, rows: 50),
        scrollbackCapacity: 100_000
    )
    let before = footprintBytes()
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for line in 0..<profileLineCount {
            parser.feed(bytes, handler: &terminal)
            if line.isMultiple(of: 256) { _ = terminal.takeEvents() }
        }
        _ = terminal.takeEvents()
    }
    let after = footprintBytes()
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let totalBytes = bytes.count * profileLineCount
    let throughput = Double(totalBytes) / seconds / 1024 / 1024
    let completionCount = commandProfile == .status
        ? terminal.commandBlocks().count
        : 0
    print("命令状态 profile: \(commandProfile.rawValue)")
    print("  行数 \(profileLineCount)  字节 \(totalBytes)")
    print("  耗时 \(elapsed)")
    print("  吞吐 \(String(format: "%.1f", throughput)) MB/s")
    print("  footprint 增量 \(mb(after - before))")
    print("  scrollback \(terminal.scrollback.count) 行")
    print("  可查询完成块 \(completionCount)")
    exit(EXIT_SUCCESS)
}

let lineCount = 100_000
let columns = 200

struct Scenario {
    let name: String
    let line: (Int) -> String
}

let scenarios: [Scenario] = [
    Scenario(name: "ASCII 均值 40 列（ls 类输出）") { i in
        "drwxr-xr-x  14 cheney  staff  \(448 + i % 512)  Jul 19 file-\(i % 1000).swift"
    },
    Scenario(name: "ASCII 满 200 列（cat 长日志）") { i in
        String(repeating: "x", count: columns - 8) + String(format: "%08d", i)
    },
    Scenario(name: "彩色输出（每行两次 SGR，约 80 列）") { i in
        "\u{1B}[32mPASS\u{1B}[0m test_case_\(i % 10_000) 完成 \u{1B}[33m\(i % 500)ms\u{1B}[0m 附加说明文字填充填充填充"
    },
    Scenario(name: "中文为主（40 汉字 = 80 列）") { i in
        String(repeating: "终端渲染测试第\(i % 10)批", count: 5)
    },
]

print("每场景 \(lineCount) 行，\(columns) 列终端\n")

// Reflow 代价：10 万行灌满后改列宽（拖拽窗口的每一档都会付一次）。
do {
    var parser = Parser()
    var terminal = Terminal(
        size: TerminalSize(columns: columns, rows: 50),
        scrollbackCapacity: lineCount
    )
    for i in 0..<lineCount {
        parser.feed(Array("drwxr-xr-x  14 cheney staff line-\(i % 1000)\r\n".utf8), handler: &terminal)
    }
    let clock = ContinuousClock()
    let narrow = clock.measure { terminal.resize(to: TerminalSize(columns: 120, rows: 50)) }
    let widen = clock.measure { terminal.resize(to: TerminalSize(columns: 200, rows: 50)) }
    print("Reflow 10 万行：变窄 \(narrow)  变宽 \(widen)\n")
}

// 搜索代价：100 个固定命中，随后追加一个新命中，最后释放瞬态缓存。
do {
    var parser = Parser()
    var terminal = Terminal(
        size: TerminalSize(columns: columns, rows: 50),
        scrollbackCapacity: lineCount
    )
    for i in 0..<lineCount {
        let marker = i % 1_000 == 0 ? " search-needle" : ""
        parser.feed(
            Array("build output line \(i)\(marker)\r\n".utf8),
            handler: &terminal
        )
    }

    let clock = ContinuousClock()
    let beforeSearch = footprintBytes()
    var index = TerminalSearchIndex()
    let full = clock.measure {
        index.update(in: terminal, query: "search-needle")
    }
    let fullCount = index.matches.count
    let cachedFootprint = footprintBytes()

    parser.feed(Array("search-needle incremental\r\n".utf8), handler: &terminal)
    let incremental = clock.measure {
        index.update(in: terminal, query: "search-needle")
    }
    let incrementalCount = index.matches.count
    let clear = clock.measure { index.clear() }
    let clearedFootprint = footprintBytes()

    print("Search 10 万行")
    print("  首次扫描 \(full)  命中 \(fullCount)")
    print("  单行增量 \(incremental)  命中 \(incrementalCount)")
    print("  结果缓存 \(mb(cachedFootprint - beforeSearch))  清理 \(clear)")
    print("  清理后相对搜索前 \(mb(clearedFootprint - beforeSearch))\n")
}

for scenario in scenarios {
    var parser = Parser()
    var terminal = Terminal(
        size: TerminalSize(columns: columns, rows: 50),
        scrollbackCapacity: lineCount
    )

    // 预生成字节流，计时只含解析与入库（吞吐数字才是解析器自己的）。
    var feed: [[UInt8]] = []
    feed.reserveCapacity(lineCount)
    var totalBytes = 0
    for i in 0..<lineCount {
        let bytes = Array("\(scenario.line(i))\r\n".utf8)
        totalBytes += bytes.count
        feed.append(bytes)
    }

    let before = footprintBytes()
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        for bytes in feed {
            parser.feed(bytes, handler: &terminal)
        }
    }
    let after = footprintBytes()

    let delta = after - before
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let throughput = Double(totalBytes) / seconds / 1024 / 1024
    print(scenario.name)
    print("  增量 \(mb(delta))（\(delta / lineCount) B/行） 解析吞吐 \(String(format: "%.0f", throughput)) MB/s")
    print("  scrollback \(terminal.scrollback.count) 行\n")
    _ = feed // 生成的数据在测量段之后释放，不影响差值方向
}
