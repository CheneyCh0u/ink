import AppKit
import Foundation

enum SafePasteRisk: Equatable {
    case multipleLines
    case controlCharacters
    case unprotectedTarget
}

struct SafePasteAssessment: Equatable {
    let lineCount: Int
    let risks: [SafePasteRisk]
}

struct SafePasteAlertContent: Equatable {
    let messageText: String
    let informativeText: String

    init(messageText: String, informativeText: String) {
        self.messageText = messageText
        self.informativeText = informativeText
    }

    init(assessment: SafePasteAssessment) {
        messageText = "粘贴 \(assessment.lineCount) 行内容？"

        let hasMultipleLines = assessment.risks.contains(.multipleLines)
        let hasControlCharacters = assessment.risks.contains(.controlCharacters)
        let detected: String
        switch (hasMultipleLines, hasControlCharacters) {
        case (true, true):
            detected = "检测到多行内容和控制字符。"
        case (true, false):
            detected = "检测到多行内容。"
        case (false, true):
            detected = "检测到控制字符。"
        case (false, false):
            detected = ""
        }

        if assessment.risks.contains(.unprotectedTarget) {
            informativeText = "\(detected)当前程序未开启 bracketed paste，内容可能被直接执行。"
        } else {
            informativeText = "\(detected)粘贴前请确认内容可信。"
        }
    }
}

enum SafePasteChoice {
    case paste
    case singleLine
    case cancel
}

@MainActor
protocol SafePastePresenting: AnyObject {
    func choose(for assessment: SafePasteAssessment) -> SafePasteChoice
}

@MainActor
final class NSAlertSafePastePresenter: SafePastePresenting {
    func choose(for assessment: SafePasteAssessment) -> SafePasteChoice {
        let content = SafePasteAlertContent(assessment: assessment)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = content.messageText
        alert.informativeText = content.informativeText

        alert.addButton(withTitle: "转为单行")
        let paste = alert.addButton(withTitle: "粘贴")
        paste.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"

        return switch alert.runModal() {
        case .alertFirstButtonReturn: .singleLine
        case .alertSecondButtonReturn: .paste
        default: .cancel
        }
    }
}

enum SafePaste {
    private static let bracketedPasteStart = "\u{1B}[200~"
    private static let bracketedPasteEnd = "\u{1B}[201~"

    static func assessment(
        for text: String,
        bracketedPaste: Bool
    ) -> SafePasteAssessment? {
        let scan = scan(text)
        var risks: [SafePasteRisk] = []
        if scan.lineCount > 1 {
            risks.append(.multipleLines)
        }
        if scan.hasControlCharacters {
            risks.append(.controlCharacters)
        }
        guard !risks.isEmpty else { return nil }
        if !bracketedPaste {
            risks.append(.unprotectedTarget)
        }
        return SafePasteAssessment(lineCount: scan.lineCount, risks: risks)
    }

    static func singleLine(_ text: String) -> String {
        var scalars = text.unicodeScalars.makeIterator()
        var result = String.UnicodeScalarView()
        var current = scalars.next()
        while let scalar = current {
            switch scalar.value {
            case 0x0D:
                result.append(" ")
                let next = scalars.next()
                if next?.value == 0x0A {
                    current = scalars.next()
                } else {
                    current = next
                }
                continue
            case 0x0A, 0x09:
                result.append(" ")
            case 0x00...0x1F, 0x7F...0x9F:
                break
            default:
                result.append(scalar)
            }
            current = scalars.next()
        }
        return String(result)
    }

    static func encoded(_ text: String, bracketedPaste: Bool) -> Data {
        // 用空格打断而不是直接删除：删除可能让标记两侧的片段重新拼出一个新的
        // ESC[201~，从而提前结束保护并把尾随文本交给 shell 执行。
        let filtered = text.replacingOccurrences(of: bracketedPasteEnd, with: " ")
        if bracketedPaste {
            return Data("\(bracketedPasteStart)\(filtered)\(bracketedPasteEnd)".utf8)
        }
        return Data(normalizingLineEndings(in: filtered).utf8)
    }

    private static func scan(_ text: String) -> (lineCount: Int, hasControlCharacters: Bool) {
        var scalars = text.unicodeScalars.makeIterator()
        var lineBreaks = 0
        var hasControlCharacters = false
        var current = scalars.next()
        while let scalar = current {
            let value = scalar.value
            if value == 0x0D {
                lineBreaks += 1
                let next = scalars.next()
                if next?.value == 0x0A {
                    current = scalars.next()
                } else {
                    current = next
                }
                continue
            } else if value == 0x0A {
                lineBreaks += 1
            } else if (0x00...0x1F).contains(value) || (0x7F...0x9F).contains(value) {
                hasControlCharacters = true
            }
            current = scalars.next()
        }
        return (lineBreaks + 1, hasControlCharacters)
    }

    private static func normalizingLineEndings(in text: String) -> String {
        var scalars = text.unicodeScalars.makeIterator()
        var result = String.UnicodeScalarView()
        var current = scalars.next()
        while let scalar = current {
            if scalar.value == 0x0D {
                result.append("\r")
                let next = scalars.next()
                if next?.value == 0x0A {
                    current = scalars.next()
                } else {
                    current = next
                }
                continue
            } else if scalar.value == 0x0A {
                result.append("\r")
            } else {
                result.append(scalar)
            }
            current = scalars.next()
        }
        return String(result)
    }
}
