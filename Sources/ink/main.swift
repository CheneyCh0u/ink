import AppKit
import InkShell

// SwiftPM 可执行目标没有 app bundle，激活策略要手动设为 regular
// 才会出现在 Dock 并接收键盘焦点。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate()
app.run()
