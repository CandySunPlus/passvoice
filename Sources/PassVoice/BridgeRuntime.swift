import AppKit
import Darwin
import Foundation

final class BridgeRuntime {
    private let helper: HelperProcess
    private let device: UUID?
    private let manual: Bool
    private let verbose: Bool
    private let resolveAction: (PassportGesture) -> PassportAction
    private let log: (String) -> Void
    private let onStatus: (PassportStatus) -> Void
    private let onDevice: (UUID, String) -> Void
    private let onExit: (Int32) -> Void
    private var bridge: PassportBridge?
    private var timer: DispatchSourceTimer?
    private var activationObserver: NSObjectProtocol?
    private var running = false
    private var stopping = false
    private var writeFailed = false

    init(
        helperURL: URL,
        device: UUID?,
        manual: Bool = false,
        verbose: Bool = false,
        resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction,
        log: @escaping (String) -> Void,
        onStatus: @escaping (PassportStatus) -> Void = { _ in },
        onDevice: @escaping (UUID, String) -> Void = { _, _ in },
        onExit: @escaping (Int32) -> Void
    ) {
        helper = HelperProcess(executable: helperURL)
        self.device = device
        self.manual = manual
        self.verbose = verbose
        self.resolveAction = resolveAction
        self.log = log
        self.onStatus = onStatus
        self.onDevice = onDevice
        self.onExit = onExit
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        let bridge = PassportBridge(
            makePlayback: BlackHolePlayback.init(onInvalidation:),
            makeDraft: manual || device == nil ? nil : MacVoiceDraft.init,
            resolveAction: resolveAction,
            sendKey: { [manual] key in
                if !manual { try PassportMacInput.send(key) }
            },
            observeInputTarget: MacInputTarget.observe,
            send: { [weak self] command in self?.send(command) },
            log: log,
            statusChanged: { [weak self] status in
                guard let self else { return }
                if status == .handshaking, !self.manual {
                    MacInputTarget.prepareFocus(for: NSWorkspace.shared.frontmostApplication)
                }
                self.onStatus(status)
            },
            verbose: verbose
        )
        self.bridge = bridge
        try helper.start(onEvent: { [weak self] event in
            guard let self, !self.stopping else { return }
            if let id = event.deviceId, event.type == "discovered" || event.type == "connected" {
                self.onDevice(id, event.deviceName ?? "Vokie Passport")
            }
            self.bridge?.receive(event)
        }, onExit: { [weak self] status in
            guard let self else { return }
            self.running = false
            self.timer?.cancel()
            self.stopObservingActivation()
            self.bridge?.shutdown()
            self.onExit(self.writeFailed ? EXIT_FAILURE : status)
        })
        running = true

        if let device {
            if !manual {
                let workspace = NSWorkspace.shared
                activationObserver = workspace.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { notification in
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    MacInputTarget.prepareFocus(for: application)
                }
                MacInputTarget.prepareFocus(for: workspace.frontmostApplication)
            }
            log("Looking for Passport \(device.uuidString). Release Vokie's connection if it is in use.")
            send(HelperCommand(type: "set-preferred-device", deviceId: device))
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(25))
            timer.setEventHandler { [weak bridge] in bridge?.tick() }
            timer.resume()
            self.timer = timer
        } else {
            log("Scanning for AI Passport.")
        }
    }

    func stop() {
        guard running, !stopping else { return }
        stopping = true
        timer?.cancel()
        stopObservingActivation()
        bridge?.shutdown()
        helper.stop()
    }

    private func stopObservingActivation() {
        guard let activationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    private func send(_ command: HelperCommand) {
        guard running else { return }
        do {
            try helper.send(command)
        } catch {
            log("Unable to send \(command.type) to Passport helper: \(error.localizedDescription)")
            guard !stopping else { return }
            writeFailed = true
            DispatchQueue.main.async { [weak self] in self?.stop() }
        }
    }
}

func logBridgeMessage(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
