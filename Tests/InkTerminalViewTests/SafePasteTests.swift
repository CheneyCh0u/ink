import AppKit
import Foundation
import Testing
import TerminalCore
@testable import InkTerminalView

@Suite("安全粘贴策略")
@MainActor
struct SafePasteTests {
    @Test("普通 Unicode 单行无需确认")
    func ordinarySingleLineIsSafe() {
        #expect(SafePaste.assessment(
            for: "echo 中文 🚀",
            bracketedPaste: false
        ) == nil)
    }

    @Test("CR LF 与 CRLF 按逻辑行计数")
    func lineEndingsCountLogicalLines() {
        let assessment = SafePaste.assessment(
            for: "one\r\ntwo\nthree\rfour",
            bracketedPaste: true
        )

        #expect(assessment == SafePasteAssessment(
            lineCount: 4,
            risks: [.multipleLines]
        ))
    }

    @Test("Tab C0 DEL 与 C1 都属于控制字符风险")
    func controlCharactersAreRisky() {
        let text = "echo\t\u{1B}\u{0}\u{7F}\u{85}done"

        #expect(SafePaste.assessment(
            for: text,
            bracketedPaste: true
        ) == SafePasteAssessment(
            lineCount: 1,
            risks: [.controlCharacters]
        ))
    }

    @Test("危险内容未受 bracketed paste 保护时追加风险")
    func unprotectedTargetAddsRisk() {
        #expect(SafePaste.assessment(
            for: "echo one\necho two",
            bracketedPaste: false
        ) == SafePasteAssessment(
            lineCount: 2,
            risks: [.multipleLines, .unprotectedTarget]
        ))
    }

    @Test("转为单行替换换行与 Tab 并移除其他控制字符")
    func singleLineRemovesControlCharacters() {
        let text = "echo\tone\r\ntwo\u{1B}[31m\u{0} three"

        #expect(SafePaste.singleLine(text) == "echo one two[31m three")
    }

    @Test("bracketed paste 用空格打断伪造结束标记后再包裹")
    func bracketedEncodingFiltersEndMarker() {
        let data = SafePaste.encoded(
            "echo one\u{1B}[201~echo two",
            bracketedPaste: true
        )

        #expect(String(decoding: data, as: UTF8.self) == "\u{1B}[200~echo one echo two\u{1B}[201~")
    }

    @Test("过滤结束标记不会让两侧片段重组出新标记")
    func filteringCannotReconstructEndMarker() {
        let data = SafePaste.encoded(
            "\u{1B}[20\u{1B}[201~1~echo PWN\n",
            bracketedPaste: true
        )
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(encoded == "\u{1B}[200~\u{1B}[20 1~echo PWN\n\u{1B}[201~")
        #expect(encoded.components(separatedBy: "\u{1B}[201~").count == 2)
    }

    @Test("无 bracketed paste 时把所有换行形式规范为单个 CR")
    func unprotectedEncodingNormalizesLineEndings() {
        let data = SafePaste.encoded(
            "one\r\ntwo\nthree\rfour",
            bracketedPaste: false
        )

        #expect(String(decoding: data, as: UTF8.self) == "one\rtwo\rthree\rfour")
    }

    @Test("确认文案显示行数和全部风险原因")
    func alertContentExplainsRisks() {
        let content = SafePasteAlertContent(assessment: SafePasteAssessment(
            lineCount: 4,
            risks: [.multipleLines, .controlCharacters, .unprotectedTarget]
        ))

        #expect(content == SafePasteAlertContent(
            messageText: "粘贴 4 行内容？",
            informativeText: "检测到多行内容和控制字符。当前程序未开启 bracketed paste，内容可能被直接执行。"
        ))
    }

    @Test("安全单行直接写入且不显示确认")
    func safeTextBypassesConfirmation() {
        let presenter = RecordingSafePastePresenter(choice: .cancel)
        let (view, writes) = makeView(bracketedPaste: false, presenter: presenter)

        view.paste(text: "echo 中文")

        #expect(presenter.assessments.isEmpty)
        #expect(writes.values.map { String(decoding: $0, as: UTF8.self) } == ["echo 中文"])
    }

    @Test("确认原样粘贴保留 bracketed paste 保护")
    func confirmedPasteUsesBracketedEncoding() {
        let presenter = RecordingSafePastePresenter(choice: .paste)
        let (view, writes) = makeView(bracketedPaste: true, presenter: presenter)

        view.paste(text: "echo one\necho two")

        #expect(presenter.assessments == [SafePasteAssessment(
            lineCount: 2,
            risks: [.multipleLines]
        )])
        #expect(writes.values.map { String(decoding: $0, as: UTF8.self) } == [
            "\u{1B}[200~echo one\necho two\u{1B}[201~",
        ])
    }

    @Test("转为单行不会发送换行或控制字符")
    func singleLineChoiceSanitizesBeforeWriting() {
        let presenter = RecordingSafePastePresenter(choice: .singleLine)
        let (view, writes) = makeView(bracketedPaste: false, presenter: presenter)

        view.paste(text: "echo one\n\ttwo\u{1B}")

        #expect(writes.values.map { String(decoding: $0, as: UTF8.self) } == ["echo one  two"])
    }

    @Test("取消危险粘贴不写入 PTY")
    func cancelledPasteWritesNothing() {
        let presenter = RecordingSafePastePresenter(choice: .cancel)
        let (view, writes) = makeView(bracketedPaste: false, presenter: presenter)

        view.paste(text: "rm one\nrm two")

        #expect(presenter.assessments.count == 1)
        #expect(writes.values.isEmpty)
    }

    @Test("确认期间 bracketed paste 关闭时按新风险重新确认")
    func modeChangeDuringConfirmationIsReassessed() {
        let terminalState = MutableTerminal(bracketedPaste: true)
        let presenter = RecordingSafePastePresenter(choices: [.paste, .paste])
        let view = TerminalMetalView(frame: .zero)
        let writes = DataWrites()
        view.terminalProvider = { terminalState.value }
        view.safePastePresenter = presenter
        view.onInput = { writes.values.append($0) }
        presenter.onChoose = { callCount in
            if callCount == 1 {
                terminalState.setBracketedPaste(false)
            }
        }

        view.paste(text: "echo one\necho two")

        #expect(presenter.assessments == [
            SafePasteAssessment(lineCount: 2, risks: [.multipleLines]),
            SafePasteAssessment(lineCount: 2, risks: [.multipleLines, .unprotectedTarget]),
        ])
        #expect(writes.values.map { String(decoding: $0, as: UTF8.self) } == [
            "echo one\recho two",
        ])
    }
}

@MainActor
private func makeView(
    bracketedPaste: Bool,
    presenter: RecordingSafePastePresenter
) -> (TerminalMetalView, DataWrites) {
    var parser = Parser()
    var terminal = Terminal(size: TerminalSize(columns: 80, rows: 24))
    if bracketedPaste {
        parser.feed(Array("\u{1B}[?2004h".utf8), handler: &terminal)
    }
    let view = TerminalMetalView(frame: .zero)
    let writes = DataWrites()
    view.terminalProvider = { terminal }
    view.safePastePresenter = presenter
    view.onInput = { writes.values.append($0) }
    return (view, writes)
}

@MainActor
private final class RecordingSafePastePresenter: SafePastePresenting {
    private let choices: [SafePasteChoice]
    var assessments: [SafePasteAssessment] = []
    var onChoose: ((Int) -> Void)?

    init(choice: SafePasteChoice) {
        choices = [choice]
    }

    init(choices: [SafePasteChoice]) {
        self.choices = choices
    }

    func choose(for assessment: SafePasteAssessment) -> SafePasteChoice {
        assessments.append(assessment)
        onChoose?(assessments.count)
        return choices[min(assessments.count - 1, choices.count - 1)]
    }
}

private final class DataWrites {
    var values: [Data] = []
}

@MainActor
private final class MutableTerminal {
    private var parser = Parser()
    var value = Terminal(size: TerminalSize(columns: 80, rows: 24))

    init(bracketedPaste: Bool) {
        setBracketedPaste(bracketedPaste)
    }

    func setBracketedPaste(_ enabled: Bool) {
        let suffix = enabled ? "h" : "l"
        parser.feed(Array("\u{1B}[?2004\(suffix)".utf8), handler: &value)
    }
}
