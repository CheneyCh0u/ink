import AppKit
import InkConfig

@MainActor
final class KeyBindingRecorderControl: NSView {
    let action: KeyBindingAction
    var onCandidate: ((KeyBindingAssignment) -> Result<Void, KeyBindingValidationIssue>)?
    private(set) var assignment: KeyBindingAssignment
    private(set) var validationMessage: String?

    private let valueLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton()
    private let clearButton = NSButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var isRecording = false
    // NSEvent monitor 只在主线程安装/移除；nonisolated(unsafe) 仅让 deinit 能兜底释放
    // AppKit 返回的非 Sendable token，所有其它访问仍由这个 @MainActor 类型串行化。
    nonisolated(unsafe) private var eventMonitor: Any?

    var hasActiveEventMonitor: Bool { eventMonitor != nil }

    init(action: KeyBindingAction, assignment: KeyBindingAssignment) {
        self.action = action
        self.assignment = assignment
        super.init(frame: .zero)
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("代码构建") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override var acceptsFirstResponder: Bool { true }

    func update(assignment: KeyBindingAssignment, issue: KeyBindingValidationIssue?) {
        self.assignment = assignment
        validationMessage = issue.map(message(for:))
        stopRecording()
        refresh()
    }

    func handle(candidate: KeyBinding) {
        apply(.binding(candidate))
    }

    func clearBinding() {
        apply(.disabled)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { stopRecording(); refresh() }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopRecording(); refresh() }
    }

    func beginRecording() {
        isRecording = true
        validationMessage = nil
        installEventMonitorIfNeeded()
        refresh()
    }

    func interceptKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        capture(event)
        return nil
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            refresh()
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            clearBinding()
            return
        }
        guard let candidate = KeyBindingAppKitAdapter.binding(from: event) else {
            validationMessage = "快捷键必须包含 Command 或 Control"
            refresh()
            return
        }
        handle(candidate: candidate)
    }

    private func build() {
        valueLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recordButton.title = "录制"
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(startRecording)
        recordButton.setAccessibilityLabel("录制\(action.displayTitle)快捷键")

        clearButton.title = "清除"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearAction)

        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.setAccessibilityLabel("快捷键错误")

        let buttons = NSStackView(views: [valueLabel, recordButton, clearButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        let stack = NSStackView(views: [buttons, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    private func apply(_ candidate: KeyBindingAssignment) {
        let wasRecording = isRecording
        switch onCandidate?(candidate) ?? .success(()) {
        case .success:
            assignment = candidate
            validationMessage = nil
            stopRecording()
        case .failure(let issue):
            validationMessage = message(for: issue)
            if wasRecording {
                isRecording = true
                installEventMonitorIfNeeded()
            }
        }
        refresh()
    }

    private func refresh() {
        valueLabel.stringValue = switch assignment {
        case .disabled: "未设置"
        case .binding(let binding): KeyBindingAppKitAdapter.displayString(for: binding)
        }
        recordButton.title = isRecording ? "请按快捷键…" : "录制"
        errorLabel.stringValue = validationMessage ?? ""
        errorLabel.isHidden = validationMessage == nil
        errorLabel.setAccessibilityValue(validationMessage)
    }

    private func message(for issue: KeyBindingValidationIssue) -> String {
        switch issue {
        case .invalidSyntax: "无法识别这个快捷键"
        case .reserved: "这个快捷键由 macOS 或终端保留"
        case .conflict(_, let actions):
            "与\(actions.filter { $0 != action }.map(\.displayTitle).joined(separator: "、"))冲突"
        }
    }

    @objc private func startRecording() {
        beginRecording()
        if let window, !window.makeFirstResponder(self) {
            stopRecording()
            refresh()
        }
    }

    @objc private func clearAction() { clearBinding() }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.interceptKeyDown(event) ?? event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
