import AppKit
import InkConfig
import InkDesign
import Testing
@testable import InkShell

@Suite("快捷键设置", .serialized)
@MainActor
struct KeyBindingSettingsTests {
    @Test("合法录制即时回传，冲突保留旧值并显示错误")
    func recordsAndRejectsConflict() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: [InkConfig] = []
        controller.onChange = { received.append($0) }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)

        newTab.handle(candidate: try #require(KeyBinding.parse("cmd+ctrl+t")))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        newTab.handle(candidate: try #require(KeyBindingSet.defaults.binding(for: .find)))
        #expect(received.last?.keyBindings.binding(for: .newTab)?.serialized == "cmd+ctrl+t")
        #expect(newTab.validationMessage?.contains("查找") == true)
    }

    @Test("快捷键错误第二行始终包含在设置行内")
    func validationMessageExpandsRowHeight() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let newTab = try recorder(.newTab, in: controller.view)

        newTab.handle(candidate: try #require(KeyBindingSet.defaults.binding(for: .find)))
        controller.view.layoutSubtreeIfNeeded()

        let row = try #require(newTab.superview)
        #expect(newTab.frame.minY >= row.bounds.minY + InkDesignTokens.Spacing.xs)
        #expect(newTab.frame.maxY <= row.bounds.maxY - InkDesignTokens.Spacing.xs)
    }

    @Test("清除、外部刷新和全部恢复默认")
    func clearRefreshAndReset() throws {
        let controller = SettingsViewController(config: InkConfig())
        var received: InkConfig?
        controller.onChange = { received = $0 }
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)

        newTab.clearBinding()
        #expect(received?.keyBindings.assignment(for: .newTab) == .disabled)

        var external = InkConfig()
        _ = external.setKeyBinding(
            .binding(try #require(KeyBinding.parse("cmd+ctrl+t"))),
            for: .newTab
        )
        controller.update(config: external)
        #expect(newTab.assignment == external.keyBindings.assignment(for: .newTab))

        controller.resetAllKeyBindings(confirm: { true })
        #expect(received?.keyBindings == .defaults)
    }

    @Test("录制监视器在菜单前消费快捷键并在结束后移除")
    func recorderInterceptsMenuEquivalent() throws {
        let recorder = KeyBindingRecorderControl(
            action: .newTab,
            assignment: .binding(try #require(KeyBindingSet.defaults.binding(for: .newTab)))
        )
        var received: KeyBindingAssignment?
        recorder.onCandidate = { received = $0; return .success(()) }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ))

        recorder.beginRecording()
        #expect(recorder.hasActiveEventMonitor)
        #expect(recorder.interceptKeyDown(event) == nil)
        #expect(received == .binding(try #require(KeyBinding.parse("cmd+t"))))
        #expect(!recorder.hasActiveEventMonitor)
    }

    @Test("Escape 取消录制并立即移除监视器")
    func escapeCancelsRecording() throws {
        let recorder = KeyBindingRecorderControl(
            action: .newTab,
            assignment: .binding(try #require(KeyBindingSet.defaults.binding(for: .newTab)))
        )
        let original = recorder.assignment
        recorder.beginRecording()

        #expect(recorder.interceptKeyDown(try keyEvent(keyCode: 53)) == nil)

        #expect(recorder.assignment == original)
        #expect(!recorder.hasActiveEventMonitor)
    }

    @Test("失去第一响应者或移出窗口都会结束录制")
    func focusAndWindowLossStopRecording() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds)
        let recorder = KeyBindingRecorderControl(
            action: .newTab,
            assignment: .binding(try #require(KeyBindingSet.defaults.binding(for: .newTab)))
        )
        let other = RecorderTestResponderView(frame: .zero)
        host.addSubview(recorder)
        host.addSubview(other)
        window.contentView = host

        #expect(window.makeFirstResponder(recorder))
        recorder.beginRecording()
        #expect(window.makeFirstResponder(other))
        #expect(!recorder.hasActiveEventMonitor)

        #expect(window.makeFirstResponder(recorder))
        recorder.beginRecording()
        recorder.removeFromSuperview()
        #expect(!recorder.hasActiveEventMonitor)
    }

    @Test("无效候选保留录制并由后续成功候选释放监视器")
    func invalidCandidateKeepsRecordingWithoutLeakingMonitor() throws {
        let recorder = KeyBindingRecorderControl(
            action: .newTab,
            assignment: .binding(try #require(KeyBindingSet.defaults.binding(for: .newTab)))
        )
        var received: KeyBindingAssignment?
        recorder.onCandidate = { received = $0; return .success(()) }
        recorder.beginRecording()

        #expect(recorder.interceptKeyDown(try keyEvent(
            characters: "t",
            charactersIgnoringModifiers: "t",
            keyCode: 17
        )) == nil)
        #expect(recorder.validationMessage == "快捷键必须包含 Command 或 Control")
        #expect(recorder.hasActiveEventMonitor)

        #expect(recorder.interceptKeyDown(try keyEvent(
            modifiers: [.command],
            characters: "t",
            charactersIgnoringModifiers: "t",
            keyCode: 17
        )) == nil)
        #expect(received == .binding(try #require(KeyBinding.parse("cmd+t"))))
        #expect(!recorder.hasActiveEventMonitor)
    }

    @Test("设置冲突候选显示错误后继续录制并可由 Escape 释放")
    func settingsConflictKeepsRecordingUntilCancelled() throws {
        let controller = SettingsViewController(config: InkConfig())
        controller.loadView()
        let newTab = try recorder(.newTab, in: controller.view)
        newTab.beginRecording()

        #expect(newTab.interceptKeyDown(try keyEvent(
            modifiers: [.command],
            characters: "f",
            charactersIgnoringModifiers: "f",
            keyCode: 3
        )) == nil)
        #expect(newTab.validationMessage?.contains("查找") == true)
        #expect(newTab.hasActiveEventMonitor)

        #expect(newTab.interceptKeyDown(try keyEvent(keyCode: 53)) == nil)
        #expect(!newTab.hasActiveEventMonitor)
    }

    private func keyEvent(
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "\u{1B}",
        charactersIgnoringModifiers: String = "\u{1B}",
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func recorder(
        _ action: KeyBindingAction,
        in view: NSView
    ) throws -> KeyBindingRecorderControl {
        if let recorder = view as? KeyBindingRecorderControl, recorder.action == action {
            return recorder
        }
        for subview in view.subviews {
            if let found = try? recorder(action, in: subview) { return found }
        }
        throw RecorderNotFound()
    }
}

private struct RecorderNotFound: Error {}

@MainActor
private final class RecorderTestResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
