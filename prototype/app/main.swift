import AppKit

// Throwaway native UI prototype. Bindings are kept in memory for this process.
private final class Canvas: NSView {
    override var isFlipped: Bool { true }

    func put<T: NSView>(_ view: T, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> T {
        view.frame = NSRect(x: x, y: y, width: w, height: h)
        addSubview(view)
        return view
    }

    @discardableResult
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
              size: CGFloat = 13, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return put(field, x, y, w, h)
    }

    func panel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Canvas {
        let panel = Canvas()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.layer?.borderWidth = 0.5
        return put(panel, x, y, w, h)
    }

    func rule(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
        let line = NSBox()
        line.boxType = .separator
        _ = put(line, x, y, w, 1)
    }
}

private final class PixelScreen: NSView {
    var image: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        image?.draw(in: bounds)
    }
}

private final class Prototype: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let width: CGFloat = 680
    private let height: CGFloat = 472
    private let gestures: [(PassportGesture, String, String)] = [
        (.downClick, "DOWN", "短按"), (.downLong, "DOWN", "长按"),
        (.okClick, "OK", "短按"), (.okLong, "OK", "长按"),
    ]
    private let actions: [(PassportAction, String, String)] = [
        (.returnKey, "回车", "return"), (.backspace, "退格", "delete.left"),
        (.deleteVoiceInput, "删除上一段语音输入", "text.badge.minus"), (.none, "不执行", "minus.circle"),
    ]
    private let settingsNames = ["紧凑列表", "按键分组", "双栏检视"]
    private let screenNames = ["大字状态", "语音到光标", "实体键提示"]
    private let stateNames = ["就绪", "录音", "收尾", "离线", "连接慢"]
    private var window: NSWindow!
    private var route = 0
    private var variants = [0, 0]
    private var bindings = [PassportGesture: PassportAction]()
    private var focusedGesture = 0
    private var deviceState = 0
    private var capturing: Int?
    private var monitor: Any?
    private var finishing: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 PassVoice 界面原型", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PassVoice 界面原型"
        window.delegate = self

        if let index = CommandLine.arguments.firstIndex(of: "--capture"), index + 1 < CommandLine.arguments.count {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            window.appearance = NSAppearance(named: .aqua)
            window.orderFront(nil)
            captureAll(to: output)
            NSApp.terminate(nil)
            return
        }

        render()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidResignKey(_ notification: Notification) {
        if capturing != nil {
            stopCapture()
            render()
        }
    }

    private func render() {
        let content = Canvas(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let surfaces = NSSegmentedControl(labels: ["Mac 按键设置", "AI Passport"], trackingMode: .selectOne,
                                          target: self, action: #selector(selectRoute(_:)))
        surfaces.selectedSegment = route
        _ = content.put(surfaces, 24, 16, 211, 25)

        let names = route == 0 ? settingsNames : screenNames
        let options = NSSegmentedControl(labels: zip(["A", "B", "C"], names).map { "\($0) \($1)" },
                                         trackingMode: .selectOne, target: self, action: #selector(selectVariant(_:)))
        options.selectedSegment = variants[route]
        _ = content.put(options, 344, 16, 312, 25)
        content.rule(24, 55, 632)

        if route == 0 {
            settings(in: content)
        } else {
            passport(in: content)
        }
        window.contentView = content
    }

    private func settings(in content: Canvas) {
        content.text("按键设置", 24, 74, 430, 30, size: 24, weight: .semibold)
        content.text("为 Passport 的 DOWN 和 OK 绑定动作。", 24, 111, 535, 19, color: .secondaryLabelColor)
        let reset = iconButton("arrow.counterclockwise", "恢复默认设置", #selector(restore))
        _ = content.put(reset, 624, 78, 32, 28)

        switch variants[0] {
        case 0: list(in: content)
        case 1: groups(in: content)
        default: inspector(in: content)
        }

        let status = capturing.map { "\(gestures[$0].1) · \(gestures[$0].2)　按下快捷键，或按 Esc 取消" }
        content.text(status ?? "原型 · 修改只在本次预览中生效", 24, 430, 620, 19, size: 12,
                     color: capturing == nil ? .secondaryLabelColor : .controlAccentColor)
    }

    private func list(in content: Canvas) {
        let panel = content.panel(24, 149, 632, 253)
        panel.text("手势", 16, 12, 140, 18, size: 11, weight: .semibold, color: .secondaryLabelColor)
        panel.text("动作", 218, 12, 200, 18, size: 11, weight: .semibold, color: .secondaryLabelColor)
        for index in gestures.indices {
            let y = CGFloat(37 + index * 52)
            panel.rule(16, y, 600)
            panel.text(gestures[index].1, 16, y + 17, 61, 18, size: 12, weight: .semibold)
            panel.text(gestures[index].2, 90, y + 17, 88, 18, color: .secondaryLabelColor)
            addAction(for: index, to: panel, x: 218, y: y + 12, width: 398)
        }
    }

    private func groups(in content: Canvas) {
        for group in 0..<2 {
            let first = group * 2
            let panel = content.panel(CGFloat(24 + group * 324), 149, 308, 240)
            let glyph = group == 0 ? "arrow.down" : "checkmark"
            let image = NSImageView(image: NSImage(systemSymbolName: glyph, accessibilityDescription: nil)!)
            image.contentTintColor = .controlAccentColor
            _ = panel.put(image, 16, 20, 16, 16)
            panel.text(gestures[first].1, 42, 17, 190, 28, size: 18, weight: .semibold)
            for row in 0..<2 {
                let index = first + row
                let y = CGFloat(57 + row * 90)
                panel.rule(16, y, 276)
                panel.text(gestures[index].2, 16, y + 11, 250, 17, size: 12,
                           weight: .medium, color: .secondaryLabelColor)
                addAction(for: index, to: panel, x: 16, y: y + 34, width: 276)
            }
        }
    }

    private func inspector(in content: Canvas) {
        let rail = content.panel(24, 149, 195, 240)
        rail.text("手势", 14, 12, 165, 17, size: 11, weight: .semibold, color: .secondaryLabelColor)
        for index in gestures.indices {
            let y = CGFloat(43 + index * 43)
            if index == focusedGesture {
                let selection = rail.panel(14, y, 167, 34)
                selection.layer?.borderWidth = 0
                selection.layer?.cornerRadius = 7
                selection.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
            }
            let row = NSButton(title: "\(gestures[index].1)    \(gestures[index].2)", target: self,
                               action: #selector(selectGesture(_:)))
            row.tag = index
            row.alignment = .left
            row.isBordered = false
            if index == focusedGesture {
                row.contentTintColor = .controlAccentColor
                row.font = .systemFont(ofSize: 13, weight: .semibold)
            }
            _ = rail.put(row, 25, y, 156, 34)
        }

        let detail = content.panel(235, 149, 421, 240)
        let (_, key, press) = gestures[focusedGesture]
        detail.text("\(key) · \(press)", 20, 19, 381, 28, size: 20, weight: .semibold)
        detail.rule(20, 63, 381)
        detail.text("执行动作", 20, 87, 381, 19, size: 12, weight: .medium, color: .secondaryLabelColor)
        addAction(for: focusedGesture, to: detail, x: 20, y: 115, width: 381)
        let current = binding(focusedGesture)
        if current == .deleteVoiceInput {
            detail.text("删除最近一次仍保留在原输入框中的语音文字。", 20, 161, 381, 21, size: 12,
                        color: .secondaryLabelColor)
        }
    }

    private func binding(_ index: Int) -> PassportAction {
        let gesture = gestures[index].0
        return bindings[gesture] ?? .defaultAction(for: gesture)
    }

    private func addAction(for index: Int, to view: Canvas, x: CGFloat, y: CGFloat, width: CGFloat) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(changeBinding(_:))
        popup.tag = index
        let gesture = "\(gestures[index].1) \(gestures[index].2)"
        popup.setAccessibilityLabel("\(gesture)动作")
        let current = binding(index)
        for (_, title, symbol) in actions {
            popup.addItem(withTitle: title)
            popup.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if case let .shortcut(_, name) = current {
            popup.addItem(withTitle: name)
            popup.lastItem?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
            popup.selectItem(at: actions.count)
        } else {
            popup.selectItem(at: actions.firstIndex { $0.0 == current } ?? 0)
        }
        _ = view.put(popup, x, y, width - 42, 29)

        let armed = capturing == index
        let record = iconButton(armed ? "xmark" : "keyboard", armed ? "取消录入" : "录入快捷键",
                                #selector(toggleCapture(_:)))
        record.tag = index
        record.setAccessibilityLabel("\(gesture) \(record.toolTip ?? "")")
        _ = view.put(record, x + width - 32, y, 32, 28)
    }

    private func iconButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func passport(in content: Canvas) {
        let shell = content.panel(24, 70, 278, 358)
        shell.layer?.cornerRadius = 31
        shell.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.17, alpha: 1).cgColor
        shell.layer?.borderColor = NSColor(srgbRed: 0.26, green: 0.32, blue: 0.39, alpha: 1).cgColor
        let screen = PixelScreen()
        screen.wantsLayer = true
        screen.layer?.cornerRadius = 25
        screen.layer?.masksToBounds = true
        let name = "\(["A", "B", "C"][variants[1]])-\(deviceState)"
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Passport-pixels") {
            screen.image = NSImage(contentsOf: url)
        }
        _ = shell.put(screen, 19, 19, 240, 320)

        let state = NSSegmentedControl(labels: stateNames, trackingMode: .selectOne, target: self,
                                       action: #selector(selectDeviceState(_:)))
        state.selectedSegment = deviceState

        content.text("AI Passport", 330, 82, 310, 30, size: 24, weight: .semibold)
        content.text("240 × 320 px · LVGL RGB565", 330, 121, 320, 20, color: .secondaryLabelColor)
        content.text("屏幕状态", 330, 170, 320, 19, size: 12, weight: .semibold)
        _ = content.put(state, 330, 197, 326, 28)
        content.rule(330, 259, 326)
        content.text("实体键模拟", 330, 279, 320, 19, size: 12, weight: .semibold)
        let names = ["UP", "DOWN", "OK"]
        let hints = ["开始 / 停止", "切换方案", "切换状态"]
        for i in names.indices {
            let x = CGFloat(330 + i * 110)
            let button = NSButton(title: names[i], target: self, action: #selector(deviceKey(_:)))
            button.tag = i
            button.toolTip = hints[i]
            button.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            _ = content.put(button, x, 307, 94, 31)
            content.text(hints[i], x + 6, 349, 100, 18, size: 11, color: .secondaryLabelColor)
        }
        content.text("预览状态和电量为示例", 330, 430, 326, 19, size: 12, color: .secondaryLabelColor)
    }

    @objc private func selectRoute(_ sender: NSSegmentedControl) {
        stopCapture()
        route = sender.selectedSegment
        render()
    }

    @objc private func selectVariant(_ sender: NSSegmentedControl) {
        stopCapture()
        variants[route] = sender.selectedSegment
        render()
    }

    @objc private func selectGesture(_ sender: NSButton) {
        stopCapture()
        focusedGesture = sender.tag
        render()
    }

    @objc private func changeBinding(_ sender: NSPopUpButton) {
        guard actions.indices.contains(sender.indexOfSelectedItem) else { return }
        stopCapture()
        bindings[gestures[sender.tag].0] = actions[sender.indexOfSelectedItem].0
        render()
    }

    @objc private func toggleCapture(_ sender: NSButton) {
        let index = sender.tag
        let wasCapturing = capturing == index
        stopCapture()
        if !wasCapturing {
            capturing = index
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.captureShortcut(event, index: index)
                return nil
            }
        }
        render()
    }

    private func captureShortcut(_ event: NSEvent, index: Int) {
        if event.keyCode != 53 {
            let flags: [(NSEvent.ModifierFlags, String)] = [
                (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
            ]
            let keys: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 51: "⌫",
                                          123: "←", 124: "→", 125: "↓", 126: "↑"]
            let modifiers = flags.filter { event.modifierFlags.contains($0.0) }.map(\.1).joined()
            let letter = (event.characters(byApplyingModifiers: []) ?? "").uppercased()
            let name = keys[event.keyCode] ?? (letter.isEmpty ? "键 \(event.keyCode)" : letter)
            let key = PassportKeystroke(keyCode: event.keyCode, modifiers: .init(rawValue: UInt64(event.modifierFlags.rawValue)))
            bindings[gestures[index].0] = .shortcut(key, keyName: modifiers + name)
        }
        stopCapture()
        render()
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = nil
    }

    @objc private func restore() {
        stopCapture()
        bindings.removeAll()
        render()
    }

    @objc private func selectDeviceState(_ sender: NSSegmentedControl) {
        finishing?.invalidate()
        deviceState = sender.selectedSegment
        render()
    }

    @objc private func deviceKey(_ sender: NSButton) {
        switch sender.tag {
        case 0:
            if deviceState == 1 {
                deviceState = 2
                finishing = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.deviceState = 0
                    if self.route == 1 { self.render() }
                }
            } else if deviceState == 0 || deviceState == 4 {
                deviceState = 1
            }
        case 1:
            variants[1] = (variants[1] + 1) % screenNames.count
        case 2:
            finishing?.invalidate()
            deviceState = (deviceState + 1) % stateNames.count
        default:
            return
        }
        render()
    }

    private func captureAll(to output: URL) {
        for surface in 0..<2 {
            route = surface
            for variant in 0..<3 {
                variants[surface] = variant
                if surface == 0 && variant == 2 { focusedGesture = 3 }
                render()
                guard let view = window.contentView?.superview else { continue }
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let label = ["A", "B", "C"][variant]
                let file = (surface == 0 ? "Mac-" : "Passport-window-") + label + ".png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(file))
            }
        }
    }
}

let application = NSApplication.shared
private let prototype = Prototype()
application.setActivationPolicy(.regular)
application.delegate = prototype
withExtendedLifetime(prototype) { application.run() }
