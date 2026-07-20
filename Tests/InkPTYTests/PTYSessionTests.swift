import Testing
@testable import InkPTY

@Suite("PTY 前台目录")
struct PTYSessionTests {

    @Test("未启动的 PTY 没有前台工作目录")
    func unstartedPTYHasNoWorkingDirectory() {
        let session = PTYSession()

        #expect(session.foregroundWorkingDirectory() == nil)
    }
}
