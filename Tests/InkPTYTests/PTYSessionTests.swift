import Foundation
import Testing
@testable import InkPTY

@Suite("PTY 前台目录", .serialized)
struct PTYSessionTests {

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
