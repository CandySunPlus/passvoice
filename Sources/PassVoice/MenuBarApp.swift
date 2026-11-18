import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import ServiceManagement

@available(macOS 13, *)
func runMenuBarApp() {
    let application = NSApplication.shared
    let delegate = PassVoiceMenuBar()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
}

@available(macOS 13, *)
private final class PassVoiceMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let logger = Logger(subsystem: "com.candysunplus.passvoice", category: "Passport")
    private let preferenceKey = "preferredPassportID"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let devices = NSMenu()
    private let bindings = PassportButtonBindings()
    private lazy var buttonSettings = PassportButtonSettings(bindings: bindings)
    private let connectionItem = NSMenuItem()
    private let connectionProblemItem = NSMenuItem()
    private let deviceMenuItem = NSMenuItem()
    private let disconnectItem = NSMenuItem()
    private let retryItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let inputMonitoringItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let loginSettingsItem = NSMenuItem()
    private var discovered: [UUID: String] = [:]
    private var selected: UUID?
    private var previousConnection = false
    private var connection: PassportStatus?
    private var runtime: BridgeRuntime?
    private var restarting = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        selected = UserDefaults.standard.string(forKey: preferenceKey).flatMap(UUID.init(uuidString:))
        setupMenu()
        startBridge()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        quitting = true
        runtime.stop()
        return .terminateLater
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            refreshPrerequisites()
            refreshLoginItem()
        }
    }

    private func setupMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        devices.autoenablesItems = false
        connectionItem.isEnabled = false
        menu.addItem(connectionItem)
        addAction(connectionProblemItem, title: "查看连接问题…", action: #selector(showConnectionProblem))
        deviceMenuItem.title = "选择 Passport"
        deviceMenuItem.submenu = devices
        menu.addItem(deviceMenuItem)
        addAction(disconnectItem, title: "断开并重新扫描", action: #selector(disconnect))
        addAction(retryItem, title: "重试", action: #selector(retry))
        menu.addItem(.separator())
        addAction(NSMenuItem(), title: "按键设置…", action: #selector(showButtonSettings))
        addAction(permissionItem, title: "授权辅助功能…", action: #selector(requestAccessibility))
        addAction(inputMonitoringItem, title: "授权输入监控…", action: #selector(requestInputMonitoring))
        audioItem.title = "需要 BlackHole 2ch"
        audioItem.isEnabled = false
        menu.addItem(audioItem)
        addAction(loginItem, title: "登录时启动", action: #selector(toggleLogin))
        addAction(loginSettingsItem, title: "打开登录项设置…", action: #selector(openLoginSettings))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 PassVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        statusItem.menu = menu
        refreshStatus()
        refreshPrerequisites()
        refreshLoginItem()
    }

    private func addAction(_ item: NSMenuItem, title: String, action: Selector) {
        item.title = title
        item.action = action
        item.target = self
        menu.addItem(item)
    }

    private func startBridge() {
        restarting = false
        previousConnection = false
        connection = nil
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/passport-helper")
        let runtime = BridgeRuntime(
            helperURL: helperURL, device: selected,
            resolveAction: bindings.action(for:),
            log: { message in Self.logger.info("\(message)") },
            onStatus: { [weak self] status in
                guard let self, !self.restarting, !self.quitting else { return }
                if status == .ready, !self.previousConnection {
                    Self.logger.notice("Passport accepted the Bluetooth handshake")
                    self.previousConnection = true
                }
                self.connection = status
                self.refreshStatus()
            },
            onDevice: { [weak self] id, name in
                guard let self, !self.restarting, !self.quitting, self.discovered[id] != name else { return }
                self.discovered[id] = name
                self.refreshStatus()
            },
            onExit: { [weak self] status in self?.bridgeExited(status: status) }
        )
        do {
            try runtime.start()
            self.runtime = runtime
        } catch {
            connection = .unavailable(error.localizedDescription)
        }
        refreshStatus()
    }

    private func bridgeExited(status: Int32) {
        runtime = nil
        if quitting {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        } else if restarting {
            startBridge()
        } else {
            connection = .unavailable("蓝牙辅助进程已退出（\(status)）。")
            refreshStatus()
        }
    }

    private func restartBridge() {
        if let runtime {
            restarting = true
            refreshStatus()
            runtime.stop()
        } else {
            startBridge()
        }
    }

    private func refreshStatus() {
        let title: String
        let symbol: String
        if restarting {
            title = "正在切换连接…"
            symbol = "waveform"
        } else {
            switch connection {
            case .handshaking:
                title = "正在握手…"
                symbol = "waveform"
            case .ready:
                title = "已连接"
                symbol = "waveform"
            case .recording:
                title = "录音中"
                symbol = "mic.fill"
            case .finishing:
                title = "正在收尾…"
                symbol = "mic"
            case .unavailable:
                title = "连接暂不可用"
                symbol = "exclamationmark.circle"
            case .disconnected, nil:
                title = selected == nil ? "正在扫描…" : previousConnection ? "正在重连…" : "正在连接…"
                symbol = "waveform"
            }
        }
        let deviceName = selected.flatMap { discovered[$0] }
        connectionItem.title = deviceName.map { "\(title) · \($0)" } ?? title
        let description = "PassVoice · \(connectionItem.title)"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "PV" : ""
            button.toolTip = description
            button.setAccessibilityLabel(description)
        }

        let hasError: Bool
        if case .unavailable = connection { hasError = true } else { hasError = false }
        connectionProblemItem.isHidden = !hasError || restarting
        retryItem.isHidden = !hasError || restarting
        disconnectItem.isHidden = selected == nil || restarting
        deviceMenuItem.isHidden = selected != nil || restarting
        if !deviceMenuItem.isHidden {
            refreshDeviceMenu()
        }
    }

    private func refreshDeviceMenu() {
        devices.removeAllItems()
        for (id, name) in discovered.sorted(by: { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }) {
            let duplicate = discovered.values.filter { $0 == name }.count > 1
            let title = duplicate ? "\(name) · \(id.uuidString.suffix(4))" : name
            let item = NSMenuItem(title: title, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.representedObject = id.uuidString
            item.target = self
            devices.addItem(item)
        }
        if devices.items.isEmpty {
            let placeholder = NSMenuItem(title: "等待附近的 Passport…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            devices.addItem(placeholder)
        }
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let id = UUID(uuidString: value), !restarting else { return }
        selected = id
        UserDefaults.standard.set(value, forKey: preferenceKey)
        restartBridge()
    }

    @objc private func disconnect() {
        selected = nil
        discovered.removeAll()
        UserDefaults.standard.removeObject(forKey: preferenceKey)
        restartBridge()
    }

    @objc private func retry() {
        restartBridge()
    }

    @objc private func showButtonSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        buttonSettings.showWindow(nil)
    }

    @objc private func showConnectionProblem() {
        guard case let .unavailable(message) = connection else { return }
        showAlert(title: "Passport 连接暂不可用", message: message)
    }

    private func refreshPrerequisites() {
        permissionItem.isHidden = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        inputMonitoringItem.isHidden = !permissionItem.isHidden || CGPreflightListenEventAccess()
        audioItem.isHidden = (try? BlackHolePlayback.deviceID()) != nil
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) || !CGRequestPostEventAccess() {
            showAlert(title: "允许 PassVoice 模拟语音快捷键",
                      message: "在「系统设置 → 隐私与安全性 → 辅助功能」中启用 PassVoice，然后重新打开菜单。")
        }
        refreshPrerequisites()
    }

    @objc private func requestInputMonitoring() {
        if !CGRequestListenEventAccess() {
            showAlert(title: "允许 PassVoice 检查语音提交期间的按键",
                      message: "在「系统设置 → 隐私与安全性 → 输入监控」中启用并重新打开 PassVoice。等待语音文字时，键盘或鼠标操作会取消暂存的回车。PassVoice 不记录按键。")
        }
        refreshPrerequisites()
    }

    private func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        loginItem.title = status == .requiresApproval ? "登录时启动（待批准）" : "登录时启动"
        loginSettingsItem.isHidden = status != .requiresApproval
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            if service.status != .requiresApproval {
                showAlert(title: "无法更改登录时启动", message: error.localizedDescription)
            }
        }
        refreshLoginItem()
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func showAlert(title: String, message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
