import AppKit
import Carbon.HIToolbox

final class PassportButtonSettings: NSWindowController, NSWindowDelegate {
    private static let gestures: [(gesture: PassportGesture, button: String, press: String)] = [
        (.downClick, "DOWN", "短按"), (.downLong, "DOWN", "长按"),
        (.okClick, "OK", "短按"), (.okLong, "OK", "长按"),
    ]
    private static let actions: [(action: PassportAction, title: String, symbol: String)] = [
        (.returnKey, "回车", "return"), (.backspace, "退格", "delete.left"),
        (.deleteVoiceInput, "删除上一段语音输入", "text.badge.minus"), (.none, "不执行", "minus.circle"),
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

        let rows = Self.gestures.map { gesture, button, press in
            let key = NSTextField(labelWithString: button)
            key.font = .systemFont(ofSize: 12, weight: .semibold)
            let gestureLabel = NSTextField(labelWithString: press)
            gestureLabel.textColor = .secondaryLabelColor
            let choice = NSPopUpButton(frame: .zero, pullsDown: false)
            choice.setAccessibilityLabel("\(button) \(press)动作")
            choice.target = self
            choice.action = #selector(changeBinding(_:))
            for (_, title, symbol) in Self.actions {
                choice.addItem(withTitle: title)
                choice.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            let record = NSButton(title: "", target: self, action: #selector(toggleRecording(_:)))
            record.bezelStyle = .rounded
            record.imagePosition = .imageOnly
            controls[gesture] = (choice, record)
            return Self.tableRow([key, gestureLabel, choice, record], height: 42)
        }
        let columns = Self.tableRow([Self.columnLabel("手势"), NSView(), Self.columnLabel("动作"), NSView()], height: 26)
        let table = Self.verticalStack([columns] + rows.flatMap { [Self.separator(), $0] }, spacing: 0)

        let panel = NSBox()
        panel.boxType = .custom
        panel.cornerRadius = 12
        panel.fillColor = .controlBackgroundColor
        panel.borderColor = .separatorColor
        panel.borderWidth = 0.5
        panel.contentViewMargins = .zero
        let tableSurface = NSView()
        panel.contentView = tableSurface
        Self.pin(table, to: tableSurface, horizontal: 16, vertical: 10)

        let title = NSTextField(labelWithString: "按键设置")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let restore = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)!,
                               target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        restore.imagePosition = .imageOnly
        restore.widthAnchor.constraint(equalToConstant: 32).isActive = true
        restore.toolTip = "恢复默认设置"
        restore.setAccessibilityLabel("恢复默认设置")
        let header = NSStackView(views: [title, NSView(), restore])
        header.alignment = .centerY
        let subtitle = NSTextField(labelWithString: "为 Passport 的 DOWN 和 OK 绑定动作。")
        subtitle.alignment = .left
        subtitle.textColor = .secondaryLabelColor
        let description = NSView()
        Self.pin(subtitle, to: description, horizontal: 0, vertical: 0)
        capturePrompt.textColor = .secondaryLabelColor
        let footer = NSView()
        Self.pin(capturePrompt, to: footer, horizontal: 0, vertical: 0)
        let content = Self.verticalStack([header, description, panel, footer], spacing: 12)
        content.setCustomSpacing(18, after: description)
        let root = NSView()
        Self.pin(content, to: root, horizontal: 24, vertical: 20)
        window.contentView = root
        refreshControls()
        window.setContentSize(root.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        NSLayoutConstraint.activate(views.map { $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor) })
        return stack
    }

    private static func tableRow(_ cells: [NSView], height: CGFloat) -> NSStackView {
        let row = NSStackView(views: cells)
        row.spacing = 12
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        let columnWidths: [CGFloat] = [64, 98, 330, 32]
        for (cell, width) in zip(cells, columnWidths) {
            cell.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return row
    }

    private static func columnLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private static func pin(_ child: NSView, to parent: NSView, horizontal: CGFloat, vertical: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: horizontal),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -horizontal),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: vertical),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -vertical),
        ])
    }

    func windowDidResignKey(_ notification: Notification) {
        guard capturing != nil else { return }
        stopRecording()
        refreshControls()
    }

    private func refreshControls() {
        for (gesture, button, press) in Self.gestures {
            guard let row = controls[gesture] else { continue }
            let action = bindings.action(for: gesture)
            if row.choice.numberOfItems > Self.actions.count {
                row.choice.removeItem(at: Self.actions.count)
            }
            if case let .shortcut(key, name) = action {
                row.choice.addItem(withTitle: "自定义（\(Self.shortcutTitle(key, name: name))）")
                row.choice.lastItem?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
                row.choice.selectItem(at: Self.actions.count)
            } else if let index = Self.actions.firstIndex(where: { $0.action == action }) {
                row.choice.selectItem(at: index)
            }
            let recording = capturing == gesture
            let hint = recording ? "取消录入" : "录入快捷键"
            row.record.image = NSImage(systemSymbolName: recording ? "xmark" : "keyboard", accessibilityDescription: nil)
            row.record.toolTip = hint
            row.record.setAccessibilityLabel("\(button) \(press) \(hint)")
        }
        capturePrompt.isHidden = capturing == nil
    }

    @objc private func changeBinding(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.actions.indices.contains(index),
              let gesture = controls.first(where: { $0.value.choice === sender })?.key else { return }
        stopRecording()
        bindings.set(Self.actions[index].action, for: gesture)
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
