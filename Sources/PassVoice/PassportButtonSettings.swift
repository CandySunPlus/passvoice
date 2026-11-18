import AppKit
import Carbon.HIToolbox

final class PassportButtonSettings: NSWindowController, NSWindowDelegate {
    private static let gestures: [(gesture: PassportGesture, button: String, press: String)] = [
        (.downClick, "DOWN", "短按"), (.downLong, "DOWN", "长按"),
        (.okClick, "OK", "短按"), (.okLong, "OK", "长按"),
    ]
    private static let actions: [(action: PassportAction, title: String, symbol: String)] = [
        (.returnKey, "回车", "return"), (.backspace, "退格", "delete.left"),
        (.undo, "撤销（⌘Z）", "arrow.uturn.backward"), (.none, "不执行", "minus.circle"),
    ]

    private static let pickerWidth: CGFloat = 168
    private static let buttonSize: CGFloat = 32
    private static let controlSpacing: CGFloat = 10

    private let bindings: PassportButtonBindings
    private let capturePrompt = NSTextField(labelWithString: "")
    private let captureIcon = NSImageView()
    private var controls: [PassportGesture: (choice: NSPopUpButton, record: NSButton)] = [:]
    private var capturing: PassportGesture?
    private var pendingShortcut: (key: PassportKeystroke, name: String)?
    private var monitor: Any?

    init(bindings: PassportButtonBindings) {
        self.bindings = bindings
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "按键设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = makeContent()
        refreshControls()
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "按键设置")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
        let heading = NSStackView(views: [icon, title])
        heading.alignment = .centerY
        heading.spacing = 10

        let restore = Self.iconButton("arrow.counterclockwise", target: self, action: #selector(restoreDefaults))
        restore.toolTip = "恢复默认设置"
        restore.setAccessibilityLabel("恢复默认设置")
        let header = Self.pairedRow(heading, restore, height: 38, trailingWidth: Self.buttonSize)

        capturePrompt.font = .systemFont(ofSize: 12)
        captureIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        let footer = NSStackView(views: [captureIcon, capturePrompt])
        footer.alignment = .centerY
        footer.spacing = 7
        let footerRow = Self.pairedRow(footer, NSView(), height: 20, trailingWidth: 0)

        let content = Self.verticalStack([header, makeMappings(), footerRow], spacing: 14)
        content.widthAnchor.constraint(equalToConstant: 448).isActive = true
        let root = NSView()
        Self.pin(content, to: root, horizontal: 24, vertical: 18)
        return root
    }

    private func makeMappings() -> NSView {
        let actionWidth = Self.pickerWidth + Self.controlSpacing + Self.buttonSize
        let labels = Self.pairedRow(Self.columnLabel("手势"), Self.columnLabel("动作"),
                                    height: 30, trailingWidth: actionWidth)
        let rows = Self.gestures.map { gesture, button, press in
            let key = PassportKeyCap(key: button, width: 52, height: 23)
            let gestureLabel = NSTextField(labelWithString: press)
            gestureLabel.font = .systemFont(ofSize: 13, weight: .medium)
            let trigger = NSStackView(views: [key, gestureLabel])
            trigger.alignment = .centerY
            trigger.spacing = 10

            let choice = NSPopUpButton(frame: .zero, pullsDown: false)
            choice.controlSize = .regular
            choice.imagePosition = .imageLeft
            choice.widthAnchor.constraint(equalToConstant: Self.pickerWidth).isActive = true
            choice.setAccessibilityLabel("\(button) \(press)动作")
            choice.target = self
            choice.action = #selector(changeBinding(_:))
            for (_, title, symbol) in Self.actions {
                choice.addItem(withTitle: title)
                choice.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }

            let record = Self.iconButton("keyboard", target: self, action: #selector(toggleRecording(_:)))
            controls[gesture] = (choice, record)
            let actions = NSStackView(views: [choice, record])
            actions.alignment = .centerY
            actions.spacing = Self.controlSpacing
            return Self.pairedRow(trigger, actions, height: 47, trailingWidth: actionWidth)
        }

        let table = Self.verticalStack([labels] + rows.flatMap { [Self.separator(), $0] }, spacing: 0)
        let panel = NSBox()
        panel.boxType = .custom
        panel.cornerRadius = 17
        panel.fillColor = .controlBackgroundColor
        panel.borderColor = .separatorColor
        panel.borderWidth = 0.5
        panel.contentViewMargins = .zero
        let surface = NSView()
        panel.contentView = surface
        Self.pin(table, to: surface, horizontal: 16, vertical: 6)
        return panel
    }

    private static func iconButton(_ symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.bezelStyle = .push
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            button.borderShape = .circle
        }
        #endif
        button.widthAnchor.constraint(equalToConstant: buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: buttonSize).isActive = true
        return button
    }

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        NSLayoutConstraint.activate(views.map { $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor) })
        return stack
    }

    private static func pairedRow(_ leading: NSView, _ trailing: NSView,
                                  height: CGFloat, trailingWidth: CGFloat) -> NSView {
        let row = NSView()
        for view in [leading, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: height),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: trailingWidth),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
        ])
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
        let recording = Self.gestures.first { $0.gesture == capturing }
        for (gesture, button, press) in Self.gestures {
            guard let row = controls[gesture] else { continue }
            let action = bindings.action(for: gesture)
            if row.choice.numberOfItems > Self.actions.count {
                row.choice.removeItem(at: Self.actions.count)
            }
            if case let .shortcut(key, name) = action {
                row.choice.addItem(withTitle: Self.shortcutTitle(key, name: name))
                row.choice.lastItem?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
                row.choice.selectItem(at: Self.actions.count)
            } else if let index = Self.actions.firstIndex(where: { $0.action == action }) {
                row.choice.selectItem(at: index)
            }
            let recording = capturing == gesture
            let hint = recording ? "取消录入" : "录入快捷键"
            row.record.image = NSImage(systemSymbolName: recording ? "xmark" : "keyboard", accessibilityDescription: nil)
            row.record.contentTintColor = recording ? .controlAccentColor : .labelColor
            row.record.toolTip = hint
            row.record.setAccessibilityLabel("\(button) \(press) \(hint)")
        }
        let color: NSColor = recording == nil ? .secondaryLabelColor : .controlAccentColor
        capturePrompt.textColor = color
        captureIcon.contentTintColor = color
        captureIcon.image = NSImage(systemSymbolName: recording == nil ? "keyboard" : "record.circle",
                                    accessibilityDescription: nil)
        if let recording {
            capturePrompt.stringValue = "\(recording.button) \(recording.press) · 按下快捷键，或点击 × 取消"
        } else {
            capturePrompt.stringValue = "点击右侧键盘图标，录入自定义快捷键"
        }
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
