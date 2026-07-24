import Testing
import TerminalCore
@testable import InkShell

@Suite("终端会话环境")
@MainActor
struct TerminalSessionEnvironmentTests {
    @Test("会话在创建时固定环境覆盖")
    func sessionKeepsEnvironmentOverrides() {
        let overrides = ["STARSHIP_CONFIG": "/tmp/ink-starship.toml"]
        let session = TerminalSession(
            size: TerminalSize(columns: 80, rows: 24),
            environmentOverrides: overrides
        )
        #expect(session.environmentOverrides == overrides)
    }
}
