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
}

enum PassportStatus: Equatable {
    case handshaking
    case ready
    case recording
    case finishing
    case disconnected
    case unavailable(String)
}

// The bridge and all playback changes run on the main queue.
final class PassportBridge {
    private enum Readiness {
        case waiting, awaitingAcknowledgment, ready
    }

    private final class Capture {
        let id: UInt32
        let generation: UUID
        let playback: AudioPlayback
        let startedAt: DispatchTime
        let playAt: DispatchTime
        var lastAudioAt: DispatchTime
        var isPlaying = false
        var frames = SessionFrames()
        var tail: (final: Int, deadline: DispatchTime)?
        var drainDeadline: DispatchTime?

        init(id: UInt32, generation: UUID, playback: AudioPlayback, now: DispatchTime, leadTime: DispatchTimeInterval) {
            self.id = id
            self.generation = generation
            self.playback = playback
            startedAt = now
            lastAudioAt = now
            playAt = now + leadTime
        }
    }

    private let makePlayback: (@escaping () -> Void) throws -> AudioPlayback
    private let tapVoiceKey: (() throws -> Void)?
    private let resolveAction: (PassportGesture) -> PassportAction
    private let sendKey: (PassportKeystroke) throws -> Void
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
    private var stopping = false

    init(
        makePlayback: @escaping (@escaping () -> Void) throws -> AudioPlayback,
        tapVoiceKey: (() throws -> Void)?,
        resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction,
        sendKey: @escaping (PassportKeystroke) throws -> Void = { _ in },
        send: @escaping (HelperCommand) -> Void,
        log: @escaping (String) -> Void,
        statusChanged: @escaping (PassportStatus) -> Void = { _ in },
        verbose: Bool = false,
        leadTime: DispatchTimeInterval = .milliseconds(350)
    ) {
        self.makePlayback = makePlayback
        self.tapVoiceKey = tapVoiceKey
        self.resolveAction = resolveAction
        self.sendKey = sendKey
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
            if let message = event.message, event.type == "error" {
                statusChanged(.unavailable(message))
            } else {
                statusChanged(.disconnected)
            }
            if let capture, capture.drainDeadline == nil {
                // Contiguous audio already queued can still finish at the input method.
                finish(capture, now: now)
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
        guard let capture else { return }
        if !capture.isPlaying, now >= capture.playAt,
           capture.frames.next > 0 || capture.drainDeadline != nil {
            capture.isPlaying = true
            do {
                try capture.playback.play()
            } catch {
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
        if capture != nil {
            if isReady { sendState("error") }
            closeCapture()
        }
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
            guard isReady, capture == nil, let id = control.sessionId, id != lastSessionID else { return }
            start(id: id, now: now)
        case "ptt_up":
            guard control.sessionId == capture?.id, let capture, capture.tail == nil,
                  capture.drainDeadline == nil, let final = control.finalSequence else { return }
            let finalFrame = final == UInt32.max ? -1 : Int(final)
            log("Passport session \(capture.id) stopped (finalSequence: \(finalFrame))")
            capture.tail = (finalFrame, now + .milliseconds(500))
            statusChanged(.finishing)
            sendState("processing")
            flush(capture, now: now)
        case "button_event":
            guard isReady, let gesture = PassportGesture(button: control.button, event: control.event) else { return }
            perform(resolveAction(gesture))
        case "device_error":
            if let capture, control.sessionId == capture.id {
                abort("Passport error: \(control.message ?? "unknown")")
            } else if capture == nil, isReady {
                log("Passport error: \(control.message ?? "unknown")")
                sendState("ready")
            }
        default:
            break
        }
    }

    private func perform(_ action: PassportAction) {
        guard capture == nil else { return }
        switch action {
        case .returnKey:
            do { try sendKey(.returnKey) }
            catch { log("Unable to send Passport keystroke: \(error.localizedDescription)") }
        case .none:
            break
        }
    }

    private func start(id: UInt32, now: DispatchTime) {
        lastSessionID = id
        let generation = UUID()
        let setupStarted = DispatchTime.now()
        do {
            let playback = try makePlayback { [weak self] in
                guard let self, self.capture?.generation == generation else { return }
                self.abort("BlackHole stopped during playback")
            }
            do {
                try tapVoiceKey?()
            } catch {
                playback.stop()
                throw error
            }
            let setupTime = DispatchTime.now().uptimeNanoseconds - setupStarted.uptimeNanoseconds
            let started = now + .nanoseconds(Int(setupTime))
            let capture = Capture(id: id, generation: generation, playback: playback, now: started, leadTime: leadTime)
            self.capture = capture
            log("Passport session \(id) started")
            statusChanged(.recording)
            tick(now: started)
        } catch {
            log("Unable to start Passport session \(id): \(error.localizedDescription)")
            resetPassport()
        }
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
        do {
            let final = capture.tail?.final
            try capture.frames.flush(final: final, force: force, enqueue: capture.playback.enqueue)
            if let final, capture.frames.next > final { finish(capture, now: now) }
        } catch {
            abort(error.localizedDescription)
        }
    }

    private func finish(_ capture: Capture, now: DispatchTime) {
        capture.drainDeadline = now + .seconds(4)
        do {
            try capture.playback.drain { [weak self, weak capture] in
                guard let self, let capture, self.capture === capture else { return }
                self.log("Passport session \(capture.id) drained \(capture.frames.next) frames (\(capture.frames.missing) silence replacements)")
                self.closeCapture()
                if self.isReady {
                    self.sendState("ready")
                    self.statusChanged(.ready)
                } else {
                    self.sendHandshake()
                }
            }
        } catch {
            abort(error.localizedDescription)
        }
    }

    private func abort(_ reason: String) {
        log(reason)
        closeCapture()
        resetPassport()
    }

    private func closeCapture() {
        guard let capture else { return }
        self.capture = nil
        capture.playback.stop()
        do {
            try tapVoiceKey?()
        } catch {
            log("Unable to end Doubao voice input: \(error.localizedDescription)")
        }
    }

    private func sendHandshake(repeatReady: Bool = false) {
        guard subscribed, helloValidated, capture == nil, readiness != .awaitingAcknowledgment,
              !isReady || repeatReady else { return }
        if !isReady { readiness = .awaitingAcknowledgment }
        send(HelperCommand(type: "host_ready"))
    }

    private func resetPassport() {
        if isReady {
            sendState("error")
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
