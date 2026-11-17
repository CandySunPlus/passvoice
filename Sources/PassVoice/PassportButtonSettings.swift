import AppKit
import Carbon.HIToolbox

final class PassportButtonSettings: NSWindowController, NSWindowDelegate {
    private static let gestures: [(PassportGesture, String)] = [
        (.downClick, "DOWN 短按"), (.downLong, "DOWN 长按"),
        (.okClick, "OK 短按"), (.okLong, "OK 长按"),
    ]
    private static let actions: [(PassportAction, String)] = [
        (.returnKey, "回车"), (.backspace, "退格"), (.deleteVoiceInput, "删除上一段语音输入"), (.none, "不执行"),
    ]

    private let bindings: PassportButtonBindings
    private let capturePrompt = NSTextField(labelWithString: "按下要绑定的快捷键")
    private var controls: [PassportGesture: (choice: NSPopUpButton, record: NSButton)] = [:]
    private var capturing: PassportGesture?
    private var pendingShortcut: (key: PassportKeystroke, name: String)?
    private var monitor: Any?

    init(bindings: PassportButtonBindings) {
        self.bindings = bindings
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "按键设置"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let rows: [[NSView]] = Self.gestures.map { gesture, title in
            let label = NSTextField(labelWithString: title)
            let choice = NSPopUpButton(frame: .zero, pullsDown: false)
            choice.setAccessibilityLabel("\(title)动作")
            choice.target = self
            choice.action = #selector(changeBinding(_:))
            choice.addItems(withTitles: Self.actions.map(\.1))
            choice.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
            let record = NSButton(title: "录入快捷键…", target: self, action: #selector(toggleRecording(_:)))
            record.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
            controls[gesture] = (choice, record)
            return [label, choice, record]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        let restore = NSButton(title: "恢复默认设置", target: self, action: #selector(restoreDefaults))
        capturePrompt.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [restore, capturePrompt])
        footer.spacing = 12
        let content = NSStackView(views: [grid, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        window.contentView = content
        refreshControls()
        window.setContentSize(content.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowDidResignKey(_ notification: Notification) {
        guard capturing != nil else { return }
        stopRecording()
        refreshControls()
    }

    private func refreshControls() {
        for (gesture, title) in Self.gestures {
            guard let row = controls[gesture] else { continue }
            let action = bindings.action(for: gesture)
            if row.choice.numberOfItems > Self.actions.count {
                row.choice.removeItem(at: Self.actions.count)
            }
            if case let .shortcut(key, name) = action {
                row.choice.addItem(withTitle: "自定义（\(Self.shortcutTitle(key, name: name))）")
                row.choice.selectItem(at: Self.actions.count)
                row.record.title = "重新录入…"
            } else if let index = Self.actions.firstIndex(where: { $0.0 == action }) {
                row.choice.selectItem(at: index)
                row.record.title = "录入快捷键…"
            }
            if capturing == gesture { row.record.title = "取消录入" }
            row.record.setAccessibilityLabel("\(title) \(row.record.title)")
        }
        capturePrompt.isHidden = capturing == nil
    }

    @objc private func changeBinding(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.actions.indices.contains(index),
              let gesture = controls.first(where: { $0.value.choice === sender })?.key else { return }
        stopRecording()
        bindings.set(Self.actions[index].0, for: gesture)
        refreshControls()
    }

    @objc private func toggleRecording(_ sender: NSButton) {
        guard let gesture = controls.first(where: { $0.value.record === sender })?.key else { return }
        let shouldStart = capturing != gesture
        stopRecording()
        if shouldStart {
            // Intercept the keystroke before AppKit can run a menu or control key equivalent.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow,
                      event.window == nil || event.window === window else { return event }
                return self.record(event)
            }
            if monitor != nil { capturing = gesture }
        }
        refreshControls()
    }

    private func record(_ event: NSEvent) -> NSEvent? {
        guard let gesture = capturing else { return event }
        if event.type == .keyDown, !event.isARepeat, pendingShortcut == nil {
            let flags = event.modifierFlags.intersection([.control, .option, .shift, .command, .numericPad, .function])
            let key = PassportKeystroke(keyCode: event.keyCode, modifiers: .init(rawValue: UInt64(flags.rawValue)))
            pendingShortcut = (key, Self.keyName(event))
        } else if event.type == .keyUp, let shortcut = pendingShortcut, event.keyCode == shortcut.key.keyCode {
            bindings.set(.shortcut(shortcut.key, keyName: shortcut.name), for: gesture)
            stopRecording()
            refreshControls()
        }
        return nil
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = nil
        pendingShortcut = nil
    }

    @objc private func restoreDefaults() {
        stopRecording()
        bindings.restoreDefaults()
        refreshControls()
    }

    private static func shortcutTitle(_ key: PassportKeystroke, name: String) -> String {
        let symbols: [(PassportKeystroke.Modifiers, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        return symbols.filter { key.modifiers.contains($0.0) }.map(\.1).joined() + name
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "空格", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeyNames[Int(event.keyCode)] { return name }
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        if let scalar = characters.unicodeScalars.first, (NSF1FunctionKey...NSF35FunctionKey).contains(Int(scalar.value)) {
            return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        }
        if !characters.isEmpty, characters.rangeOfCharacter(from: .controlCharacters) == nil {
            return characters.uppercased()
        }
        return "键 \(event.keyCode)"
    }
}
