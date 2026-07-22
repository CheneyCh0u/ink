import AppKit
import Foundation
import Testing
@testable import InkShell

@Suite("侧边栏项目拖入", .serialized)
@MainActor
struct SidebarProjectDropTests {
    @Test("内部项目拖动优先解码为排序")
    func decodesInternalReorderFirst() throws {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setString("3", forType: SidebarViewController.dragType)
        item.setString("file:///tmp/project", forType: .fileURL)
        #expect(pasteboard.writeObjects([item]))

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .reorder(3))
    }

    @Test("Finder 多目录保持 pasteboard 顺序")
    func decodesFinderDirectoriesInOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-sidebar-drop-\(UUID().uuidString)")
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pasteboard = makePasteboard()
        #expect(pasteboard.writeObjects([fileURLItem(first), fileURLItem(second)]))

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .importDirectories([
            first.standardizedFileURL,
            second.standardizedFileURL,
        ]))
    }

    @Test("普通文件拖入被拒绝")
    func rejectsFiles() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-sidebar-drop-\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pasteboard = makePasteboard()
        #expect(pasteboard.writeObjects([fileURLItem(file)]))

        #expect(SidebarProjectDropDecoder.intent(from: pasteboard) == .reject)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("ink.sidebar-drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func fileURLItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
}
