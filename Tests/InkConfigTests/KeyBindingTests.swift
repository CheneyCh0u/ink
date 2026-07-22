import Foundation
import Testing
@testable import InkConfig

@Suite("快捷键配置")
struct KeyBindingTests {
    @Test("快捷键 TOML 缺省、覆盖、禁用与非法项往返")
    func keyBindingTOMLRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ink-keybindings-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        [keybindings]
        new_tab = "ctrl+shift+t"
        split_left = "cmd+ctrl+left"
        split_right = ""
        find = "cmd+q"
        """.write(to: file, atomically: true, encoding: .utf8)

        let loaded = InkConfig.load(from: file)
        #expect(loaded.keyBindings.binding(for: .newTab)?.serialized == "ctrl+shift+t")
        #expect(loaded.keyBindings.assignment(for: .splitRight) == .disabled)
        #expect(loaded.keyBindings.binding(for: .find) == KeyBindingSet.defaults.binding(for: .find))
        #expect(loaded.keyBindingIssues[.find] != nil)

        try loaded.save(to: file)
        let reloaded = InkConfig.load(from: file)
        #expect(reloaded.keyBindings == loaded.keyBindings)
    }

    @Test("默认 action 完整且非空绑定唯一")
    func defaultsAreCompleteAndUnique() {
        let defaults = KeyBindingSet.defaults
        #expect(KeyBindingAction.allCases.allSatisfy {
            defaults.assignment(for: $0) != nil
        })
        let enabled = KeyBindingAction.allCases.compactMap {
            defaults.binding(for: $0)
        }
        #expect(Set(enabled).count == enabled.count)
        #expect(defaults.binding(for: .newTab)?.serialized == "cmd+t")
        #expect(defaults.binding(for: .splitPrefix)?.serialized == "cmd+d")
        #expect(defaults.assignment(for: .splitLeft) == .disabled)
    }

    @Test("解析别名并生成规范字符串")
    func parserNormalizesAliases() throws {
        let binding = try #require(
            KeyBinding.parse("Control+Option+Shift+Command+LEFT")
        )
        #expect(binding.serialized == "cmd+ctrl+alt+shift+left")
        #expect(KeyBinding.parse("shift+a") == nil)
        #expect(KeyBinding.parse("cmd+a+b") == nil)
        #expect(KeyBinding.parse("cmd+cmd+a") == nil)
        #expect(KeyBinding.parse("cmd+f21") == nil)
        #expect(KeyBinding.parse("cmd+") == nil)
    }

    @Test("特殊键与功能键均能规范往返")
    func specialKeysRoundTrip() {
        for key in [
            "plus", "minus", "comma", "period", "slash", "semicolon",
            "quote", "backslash", "left_bracket", "right_bracket", "backtick",
            "left", "right", "up", "down", "home", "end", "page_up", "page_down",
            "return", "tab", "space", "escape", "delete", "forward_delete", "f1", "f20",
        ] {
            let text = "ctrl+\(key)"
            #expect(KeyBinding.parse(text)?.serialized == text)
        }
    }

    @Test("禁用、保留和冲突逐项回退")
    func resolutionIsAtomicPerAction() {
        let resolved = KeyBindingSet.resolving([
            "new_tab": "",
            "find": "cmd+q",
            "copy_command": "cmd+ctrl+k",
            "copy_output": "cmd+ctrl+k",
            "focus_left": "broken",
        ])
        #expect(resolved.bindings.assignment(for: .newTab) == .disabled)
        #expect(
            resolved.bindings.binding(for: .find)
                == KeyBindingSet.defaults.binding(for: .find)
        )
        #expect(
            resolved.bindings.binding(for: .copyCommand)
                == KeyBindingSet.defaults.binding(for: .copyCommand)
        )
        #expect(
            resolved.bindings.binding(for: .copyOutput)
                == KeyBindingSet.defaults.binding(for: .copyOutput)
        )
        #expect(resolved.issues[.find] != nil)
        #expect(resolved.issues[.copyCommand] != nil)
        #expect(resolved.issues[.copyOutput] != nil)
        #expect(resolved.issues[.focusLeft] != nil)
    }

    @Test("两个 action 可以交换默认绑定")
    func defaultsCanBeSwapped() {
        let resolved = KeyBindingSet.resolving([
            "new_tab": "cmd+f",
            "find": "cmd+t",
        ])
        #expect(resolved.issues.isEmpty)
        #expect(resolved.bindings.binding(for: .newTab)?.serialized == "cmd+f")
        #expect(resolved.bindings.binding(for: .find)?.serialized == "cmd+t")
    }

    @Test("单项替换遇到冲突时保持原集合")
    func replacingRejectsConflict() throws {
        let defaults = KeyBindingSet.defaults
        let duplicate = try #require(defaults.binding(for: .find))
        let result = defaults.replacing(.newTab, with: .binding(duplicate))
        switch result {
        case .success:
            Issue.record("与查找冲突时不应接受")
        case .failure(let issue):
            guard case .conflict(let binding, let actions) = issue else {
                Issue.record("应返回 conflict")
                return
            }
            #expect(binding == duplicate)
            #expect(actions.contains(.find))
        }
    }
}
