import Foundation
import Testing
@testable import InkPTY

@Suite("PTY 前台目录", .serialized)
struct PTYSessionTests {

    @Test("PTY 子环境移除宿主 NO_COLOR 并保留其他变量")
    func childEnvironmentRemovesHostNoColor() {
        let environment = PTYSession.childEnvironment(from: [
            "NO_COLOR": "1",
            "TERM": "dumb",
            "COLORTERM": "",
            "LANG": "en_US.UTF-8",
            "INK_SENTINEL": "preserved",
        ])

        #expect(environment["NO_COLOR"] == nil)
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
        #expect(environment["TERM_PROGRAM"] == "ink")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["INK_SENTINEL"] == "preserved")
    }

    @Test("前台进程按实际 shell 身份分类")
    func classifiesForegroundProcessBySpawnedShellIdentity() {
        #expect(PTYSession.classifyForegroundProcess(
            childPID: 42,
            shellProcessGroupID: nil,
            shellName: "nu",
            masterIsOpen: true,
            foregroundPGID: 43,
            foregroundParentPID: 42,
            foregroundName: "nu"
        ) == .shell(name: "nu"))

        #expect(PTYSession.classifyForegroundProcess(
            childPID: 42,
            shellProcessGroupID: 43,
            shellName: "nu",
            masterIsOpen: true,
            foregroundPGID: 99,
            foregroundParentPID: 43,
            foregroundName: "claude"
        ) == .program(name: "claude"))

        #expect(PTYSession.classifyForegroundProcess(
            childPID: 42,
            shellProcessGroupID: nil,
            shellName: "nu",
            masterIsOpen: true,
            foregroundPGID: 99,
            foregroundParentPID: 43,
            foregroundName: "nu"
        ) == .program(name: "nu"))
    }

    @Test("退出与查询失败采用安全分类")
    func classifiesExitedAndUnknownForegroundProcess() {
        #expect(PTYSession.classifyForegroundProcess(
            childPID: -1,
            shellProcessGroupID: nil,
            shellName: "zsh",
            masterIsOpen: false,
            foregroundPGID: nil,
            foregroundParentPID: nil,
            foregroundName: nil
        ) == .exited)

        #expect(PTYSession.classifyForegroundProcess(
            childPID: 42,
            shellProcessGroupID: nil,
            shellName: "zsh",
            masterIsOpen: true,
            foregroundPGID: nil,
            foregroundParentPID: nil,
            foregroundName: nil
        ) == .program(name: nil))
    }

    @Test("真实 PTY 区分空闲 shell 与前台作业")
    func foregroundProcessTracksJobControl() throws {
        let session = PTYSession()
        try session.start(columns: 80, rows: 24)
        defer { session.terminate() }

        let shellDeadline = ContinuousClock.now + .seconds(3)
        var sawShell = false
        while ContinuousClock.now < shellDeadline {
            if case .shell = session.foregroundProcess() {
                sawShell = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(sawShell)

        session.write(Data("sleep 2\n".utf8))
        let jobDeadline = ContinuousClock.now + .seconds(1)
        var sawSleep = false
        while ContinuousClock.now < jobDeadline {
            if case .program(name: "sleep") = session.foregroundProcess() {
                sawSleep = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(sawSleep)
    }

    @Test("前台 shell 改变目录后返回实时工作目录")
    func foregroundWorkingDirectoryTracksShell() throws {
        let session = PTYSession()
        try session.start(
            columns: 80,
            rows: 24,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        defer { session.terminate() }

        session.write(Data("cd /private/tmp\n".utf8))

        let deadline = ContinuousClock.now + .seconds(3)
        var foundExpectedDirectory = false
        while ContinuousClock.now < deadline {
            if session.foregroundWorkingDirectory() == "/private/tmp" {
                foundExpectedDirectory = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(foundExpectedDirectory, "前台 shell 的工作目录没有更新为 /private/tmp")
    }

    @Test("未启动的 PTY 没有前台工作目录")
    func unstartedPTYHasNoWorkingDirectory() {
        let session = PTYSession()

        #expect(session.foregroundWorkingDirectory() == nil)
    }
}
