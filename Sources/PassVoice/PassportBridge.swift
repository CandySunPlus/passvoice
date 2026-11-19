import Foundation

struct HelperEvent: Decodable {
    let type: String
    let deviceId: UUID?
    let deviceName: String?
    let sessionId: UInt32?
    let sequence: UInt32?
    let payloadBase64: Data?
    let message: String?
}

struct PassportControl: Decodable {
    let v: Int
    let type: String
    let device: String?
    let codec: String?
    let sampleRate: Int?
    let channels: Int?
    let frameMs: Int?
    let sessionId: UInt32?
    let finalSequence: UInt32?
    let message: String?

    let button: String?
    let event: String?

    var isSupportedHello: Bool {
        device == "ai-passport" && codec == "ima-adpcm"
            && sampleRate == Int(ADPCM.sampleRate) && channels == 1 && frameMs == 20
    }
}

struct HelperCommand: Encodable {
    let type: String
    var deviceId: UUID?
    var state: String?
    var host: String?
    var cancelVoice: Bool?
}

enum PassportStatus: Equatable {
    case handshaking
    case ready
    case recording
    case finishing
    case disconnected
    case unavailable(String)
}

protocol PassportInputTarget: AnyObject {
    var isFocused: Bool { get }
    func send(_ key: PassportKeystroke) throws
}

protocol PassportVoiceDraft: AnyObject {
    var isFocused: Bool { get }

    func start(canRetry: @escaping () -> Bool, _ completion: @escaping (Result<Void, Error>) -> Void)
    // A nil result means no text was inserted.
    func finish(_ completion: @escaping (Result<PassportInputTarget?, Error>) -> Void)
    func cancel(_ completion: @escaping () -> Void)
}

// The bridge, draft, and playback changes run on the main queue.
final class PassportBridge {
    private enum Readiness {
        case waiting, awaitingAcknowledgment, ready
    }

    private final class Capture {
        let id: UInt32
        let generation: UUID
        let playback: AudioPlayback
        let draft: PassportVoiceDraft?
        let startedAt: DispatchTime
        var playAt: DispatchTime?
        var lastAudioAt: DispatchTime
        var isPlaying = false
        var frames = SessionFrames()
        var tail: (final: Int, deadline: DispatchTime)?
        var drainDeadline: DispatchTime?
        var finishingDraft = false
        var pendingKey: PassportKeystroke?

        init(id: UInt32, generation: UUID, playback: AudioPlayback, draft: PassportVoiceDraft?,
             now: DispatchTime) {
            self.id = id
            self.generation = generation
            self.playback = playback
            self.draft = draft
            startedAt = now
            lastAudioAt = now
        }
    }

    private struct EarlyReturn {
        let id: UInt32
        let deadline: DispatchTime
        let target: PassportInputTarget
    }

    private let makePlayback: (@escaping () -> Void) throws -> AudioPlayback
    private let makeDraft: (() throws -> PassportVoiceDraft)?
    private let resolveAction: (PassportGesture) -> PassportAction
    private let sendKey: (PassportKeystroke) throws -> Void
    private let observeInputTarget: () -> PassportInputTarget?
    private let send: (HelperCommand) -> Void
    private let log: (String) -> Void
    private let statusChanged: (PassportStatus) -> Void
    private let verbose: Bool
    private let leadTime: DispatchTimeInterval
    private var subscribed = false
    private var helloValidated = false
    private var readiness = Readiness.waiting
    private var isReady: Bool { readiness == .ready }
    private var discoveredDevices = Set<UUID>()
    private var lastSessionID: UInt32?
    private var capture: Capture?
    private var closingDraft = false
    private var earlyReturn: EarlyReturn?
    private var deliveredTaggedKeys = Set<PassportKeystroke>()
    private var committedTarget: PassportInputTarget?
    private var stopping = false

    init(
        makePlayback: @escaping (@escaping () -> Void) throws -> AudioPlayback,
        makeDraft: (() throws -> PassportVoiceDraft)? = nil,
        resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction,
        sendKey: @escaping (PassportKeystroke) throws -> Void = { _ in },
        observeInputTarget: @escaping () -> PassportInputTarget? = { nil },
        send: @escaping (HelperCommand) -> Void,
        log: @escaping (String) -> Void,
        statusChanged: @escaping (PassportStatus) -> Void = { _ in },
        verbose: Bool = false,
        leadTime: DispatchTimeInterval = .milliseconds(350)
    ) {
        self.makePlayback = makePlayback
        self.makeDraft = makeDraft
        self.resolveAction = resolveAction
        self.sendKey = sendKey
        self.observeInputTarget = observeInputTarget
        self.send = send
        self.log = log
        self.statusChanged = statusChanged
        self.verbose = verbose
        self.leadTime = leadTime
    }

    func receive(_ event: HelperEvent, now: DispatchTime = .now()) {
        guard !stopping else { return }
        switch event.type {
        case "discovered":
            if let id = event.deviceId, discoveredDevices.insert(id).inserted {
                log("Discovered \(event.deviceName ?? "Vokie Passport"): \(id.uuidString)")
            }
        case "connected":
            log("Connected to \(event.deviceName ?? "Vokie Passport")")
            statusChanged(.handshaking)
        case "subscribed":
            subscribed = true
            sendHandshake()
        case "host_ready_ack":
            guard readiness == .awaitingAcknowledgment else { return }
            readiness = .ready
            log("Passport ready. Press UP to start or stop.")
            statusChanged(.ready)
        case "disconnected", "error":
            log(event.message ?? "Passport disconnected. Waiting to reconnect.")
            subscribed = false
            helloValidated = false
            readiness = .waiting
            lastSessionID = nil
            earlyReturn = nil
            deliveredTaggedKeys.removeAll()
            committedTarget = nil
            if let message = event.message, event.type == "error" {
                statusChanged(.unavailable(message))
            } else {
                statusChanged(.disconnected)
            }
            if let capture, capture.draft == nil {
                // Manual mode may finish audio that was already queued.
                if capture.drainDeadline == nil {
                    drain(capture, now: now)
                }
            } else {
                discardCapture { [weak self] in self?.sendHandshake() }
            }
        case "control":
            guard let payload = event.payloadBase64,
                  let control = try? JSONDecoder().decode(PassportControl.self, from: payload),
                  control.v == 1 else { return }
            receiveControl(control, now: now)
        case "audio":
            receiveAudio(event, now: now)
        case "diagnostic":
            if let message = event.message { log("Helper: \(message)") }
        default:
            break
        }
    }

    func tick(now: DispatchTime = .now()) {
        if let earlyReturn, now >= earlyReturn.deadline { self.earlyReturn = nil }
        guard let capture, !capture.finishingDraft else { return }
        if capture.playAt != nil, capture.draft?.isFocused == false {
            abort("The Passport voice draft lost focus")
            return
        }
        if let playAt = capture.playAt, !capture.isPlaying, now >= playAt,
           capture.frames.next > 0 || capture.drainDeadline != nil {
            capture.isPlaying = true
            do { try capture.playback.play() }
            catch {
                abort(error.localizedDescription)
                return
            }
        }
        if let deadline = capture.drainDeadline {
            if now >= deadline { abort("Timed out waiting for BlackHole playback") }
        } else if let tail = capture.tail {
            if now >= tail.deadline { flush(capture, force: true, now: now) }
        } else if now >= capture.lastAudioAt + .seconds(3) {
            abort("Passport stopped sending valid audio")
        } else if now >= capture.startedAt + .seconds(300) {
            abort("Passport session reached the five-minute limit")
        }
    }

    func shutdown() {
        stopping = true
        if capture != nil, isReady { sendState("error") }
        discardCapture {}
    }

    private func receiveControl(_ control: PassportControl, now: DispatchTime) {
        switch control.type {
        case "hello":
            guard control.isSupportedHello else {
                let message = "Unsupported Passport hello. Expected BLE V1, IMA ADPCM, 16 kHz mono, 20 ms frames."
                log(message)
                if !isReady { statusChanged(.unavailable(message)) }
                return
            }
            helloValidated = true
            sendHandshake(repeatReady: true)
        case "ptt_down":
            guard isReady, capture == nil, !closingDraft, let id = control.sessionId, id != lastSessionID else { return }
            start(id: id, now: now)
        case "ptt_up":
            guard let capture, control.sessionId == capture.id, capture.tail == nil,
                  capture.drainDeadline == nil, let final = control.finalSequence else { return }
            let finalFrame = final == UInt32.max ? -1 : Int(final)
            log("Passport session \(capture.id) stopped (finalSequence: \(finalFrame))")
            capture.tail = (finalFrame, now + .milliseconds(500))
            statusChanged(.finishing)
            sendState("processing")
            flush(capture, now: now)
        case "ptt_cancel":
            guard let capture, control.sessionId == capture.id, capture.tail == nil else { return }
            discardCapture { [weak self] in
                self?.log("Passport voice session cancelled")
                self?.reportReady()
            }
        case "button_event":
            guard isReady, let gesture = PassportGesture(button: control.button, event: control.event) else { return }
            handleButton(resolveAction(gesture), sessionID: control.sessionId, now: now)
        case "device_error":
            if earlyReturn?.id == control.sessionId { earlyReturn = nil }
            if let capture, control.sessionId == capture.id {
                abort("Passport error: \(control.message ?? "unknown")")
            } else if capture == nil, !closingDraft, isReady {
                sendState("ready")
            }
        default:
            break
        }
    }

    private func handleButton(_ action: PassportAction, sessionID: UInt32?, now: DispatchTime) {
        guard !closingDraft else { return }
        let key: PassportKeystroke
        switch action {
        case .returnKey: key = .returnKey
        case .undo, .deleteVoiceInput: key = .undo
        case .backspace: key = .backspace
        case let .shortcut(shortcut, _): key = shortcut
        case .none: return
        }
        let canDefer = action == .returnKey || action == .undo || action == .deleteVoiceInput

        if let capture {
            guard canDefer, capture.draft != nil else { return }
            if let sessionID {
                guard sessionID == capture.id, capture.tail != nil || action == .returnKey else { return }
            } else {
                guard capture.tail != nil else { return }
            }
            capture.pendingKey = key
            return
        }
        if let sessionID {
            guard canDefer, sessionID != 0 else { return }
            if sessionID == lastSessionID {
                guard let committedTarget, deliveredTaggedKeys.insert(key).inserted else { return }
                sendKeystroke(key, to: committedTarget)
            } else if action == .returnKey, earlyReturn?.id != sessionID, let target = observeInputTarget() {
                earlyReturn = EarlyReturn(id: sessionID, deadline: now + .seconds(3), target: target)
            }
            return
        }
        sendKeystroke(key)
    }

    private func sendKeystroke(_ key: PassportKeystroke, to target: PassportInputTarget? = nil) {
        do {
            if let target {
                guard target.isFocused else { return }
                try target.send(key)
            } else {
                try sendKey(key)
            }
        } catch {
            log("Unable to send Passport keystroke: \(error.localizedDescription)")
        }
    }

    private func start(id: UInt32, now: DispatchTime) {
        lastSessionID = id
        committedTarget = nil
        deliveredTaggedKeys.removeAll()
        let generation = UUID()
        do {
            let draft = try makeDraft?()
            let playback = try makePlayback { [weak self] in
                guard let self, self.capture?.generation == generation else { return }
                self.abort("BlackHole stopped during playback")
            }
            let capture = Capture(id: id, generation: generation, playback: playback, draft: draft, now: now)
            if let earlyReturn, earlyReturn.id == id, now < earlyReturn.deadline, earlyReturn.target.isFocused {
                capture.pendingKey = .returnKey
            }
            earlyReturn = nil
            self.capture = capture
            log("Passport session \(id) started")
            statusChanged(.recording)
            if let draft {
                draft.start(canRetry: { [weak self, weak capture] in
                    guard let self, let capture else { return false }
                    return self.capture === capture && capture.tail == nil
                }) { [weak self, weak capture] result in
                    guard let self, let capture, self.capture === capture else { return }
                    switch result {
                    case .success: self.startPlayback(capture, now: .now())
                    case let .failure(error): self.abort(error.localizedDescription)
                    }
                }
            } else {
                startPlayback(capture, now: now)
            }
        } catch {
            abort("Unable to start Passport session \(id): \(error.localizedDescription)")
        }
    }

    private func startPlayback(_ capture: Capture, now: DispatchTime) {
        capture.playAt = now + leadTime
        flush(capture, now: now)
        tick(now: now)
    }

    private func receiveAudio(_ event: HelperEvent, now: DispatchTime) {
        guard let capture, event.sessionId == capture.id, capture.drainDeadline == nil,
              let sequence = event.sequence, let payload = event.payloadBase64 else { return }
        let index = Int(sequence)
        if let tail = capture.tail, index > tail.final { return }
        guard let samples = ADPCM.decode(payload),
              capture.frames.insert(sequence: index, samples: samples) else { return }
        capture.lastAudioAt = now
        if verbose { log("Passport session \(capture.id) audio sequence: \(sequence)") }
        flush(capture, now: now)
    }

    private func flush(_ capture: Capture, force: Bool = false, now: DispatchTime) {
        guard capture.playAt != nil else { return }
        do {
            let final = capture.tail?.final
            try capture.frames.flush(final: final, force: force, enqueue: capture.playback.enqueue)
            if let final, capture.frames.next > final { drain(capture, now: now) }
        } catch {
            abort(error.localizedDescription)
        }
    }

    private func drain(_ capture: Capture, now: DispatchTime) {
        capture.drainDeadline = now + .seconds(4)
        do {
            try capture.playback.drain { [weak self, weak capture] in
                guard let self, let capture, self.capture === capture else { return }
                capture.playback.stop()
                self.log("Passport session \(capture.id) drained \(capture.frames.next) frames (\(capture.frames.missing) silence replacements)")
                if let draft = capture.draft {
                    capture.finishingDraft = true
                    draft.finish { [weak self, weak capture] result in
                        guard let self, let capture, self.capture === capture else { return }
                        switch result {
                        case let .success(target): self.complete(capture, target: target)
                        case let .failure(error): self.abort(error.localizedDescription)
                        }
                    }
                } else {
                    self.complete(capture, target: nil)
                }
            }
        } catch {
            abort(error.localizedDescription)
        }
    }

    private func complete(_ capture: Capture, target: PassportInputTarget?) {
        self.capture = nil
        committedTarget = target
        if let target, let key = capture.pendingKey {
            deliveredTaggedKeys.insert(key)
            sendKeystroke(key, to: target)
        }
        reportReady()
    }

    private func discardCapture(then completion: @escaping () -> Void) {
        earlyReturn = nil
        guard let capture else {
            if !closingDraft { completion() }
            return
        }
        self.capture = nil
        if !capture.finishingDraft { capture.playback.stop() }
        if let draft = capture.draft {
            closingDraft = true
            draft.cancel { [weak self] in
                guard let self else { return }
                self.closingDraft = false
                if !self.stopping { completion() }
            }
        } else {
            completion()
        }
    }

    private func abort(_ reason: String) {
        log(reason)
        discardCapture { [weak self] in
            guard let self else { return }
            if self.isReady { self.sendState("error") }
            self.reportReady()
        }
    }

    private func sendHandshake(repeatReady: Bool = false) {
        guard subscribed, helloValidated, capture == nil, !closingDraft, readiness != .awaitingAcknowledgment,
              !isReady || repeatReady else { return }
        if !isReady { readiness = .awaitingAcknowledgment }
        send(HelperCommand(type: "host_ready", host: "passvoice", cancelVoice: makeDraft == nil ? nil : true))
    }

    private func reportReady() {
        if isReady {
            sendState("ready")
            statusChanged(.ready)
        } else {
            sendHandshake()
        }
    }

    private func sendState(_ state: String) {
        send(HelperCommand(type: "host_state", state: state))
    }
}
