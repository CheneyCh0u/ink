import Foundation
import Testing
@testable import InkShell

@Suite("项目目录导入规划")
struct ProjectDirectoryImportTests {
    @Test("只保留存在的本地目录并按输入顺序去重")
    func validatesDirectoriesInPayloadOrder() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")
        let file = try fixture.makeFile("notes.txt")

        let result = ProjectDirectoryImportPlanner.validDirectories(from: [
            first,
            URL(string: "https://example.com/project")!,
            file,
            first.appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("first", isDirectory: true),
            fixture.root.appendingPathComponent("missing", isDirectory: true),
            second,
        ])

        #expect(result == [first.standardizedFileURL, second.standardizedFileURL])
    }

    @Test("追加所有新目录并选择第一个新增项目")
    func plansNewDirectories() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let existing = try fixture.makeDirectory("existing")
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [existing, first, second],
            existingDirectories: [existing]
        )

        #expect(plan == ProjectDirectoryImportPlan(
            directoriesToAdd: [first.standardizedFileURL, second.standardizedFileURL],
            selectedIndex: 1
        ))
    }

    @Test("没有新增目录时选择 payload 中第一个已有项目")
    func selectsFirstExistingDuplicate() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeDirectory("first")
        let second = try fixture.makeDirectory("second")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [second, first],
            existingDirectories: [first, second]
        )

        #expect(plan.directoriesToAdd.isEmpty)
        #expect(plan.selectedIndex == 1)
    }

    @Test("全部无效时不追加也不选择")
    func rejectsInvalidPayload() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let file = try fixture.makeFile("notes.txt")

        let plan = ProjectDirectoryImportPlanner.plan(
            candidates: [file],
            existingDirectories: []
        )

        #expect(plan == ProjectDirectoryImportPlan(
            directoriesToAdd: [],
            selectedIndex: nil
        ))
    }

    @Test("符号链接目录保留链接路径")
    func preservesDirectorySymlink() throws {
        let fixture = try DirectoryImportFixture()
        defer { fixture.cleanUp() }
        let target = try fixture.makeDirectory("target")
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = ProjectDirectoryImportPlanner.validDirectories(from: [link])

        #expect(result == [link.standardizedFileURL])
    }
}

private struct DirectoryImportFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ink-directory-import-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
