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

    private struct VoiceOrigin {
        let target: PassportVoiceTarget
        let baseline: PassportTextState

        func snapshot() -> PassportTextState? {
            guard target.canConfirmVoiceText else { return nil }
            return target.snapshot()
        }

        var isUnchanged: Bool { snapshot() == baseline }
    }

    private struct VoiceCommitWait {
        let deadline: DispatchTime
        var origin: VoiceOrigin?
        var stopShortcutSent = false
        var returnQueued = false
    }

    private struct EarlyReturn {
        let id: UInt32
        let deadline: DispatchTime
        let origin: VoiceOrigin?
    }

    private final class CommittedVoiceInput {
        private enum PendingEdit { case typing, other }

        let target: PassportVoiceTarget
        private(set) var snapshot: PassportTextState
        private(set) var range: NSRange
        private var pendingEdit: PendingEdit?
        var inputPending: Bool { pendingEdit != nil }

        init(target: PassportVoiceTarget, snapshot: PassportTextState, range: NSRange) {
            self.target = target
            self.snapshot = snapshot
            self.range = range
        }

        func apply(_ observation: PassportEditObservation) -> Bool {
            switch observation {
            case let .value(updated):
                // A value notification with identical text can be a same-text replacement
                // or a pair of edits coalesced by the input. Neither preserves attribution.
                guard let pendingEdit, !updated.hasSameText(as: snapshot),
                      pendingEdit != .typing || snapshot.insertedRange(in: updated) != nil,
                      let retained = snapshot.retainedRange(range, in: updated),
                      NSIntersectionRange(retained, updated.selectedRange).length == 0 else { return false }
                snapshot = updated
                range = retained
                self.pendingEdit = nil
                return true
            case let .selection(updated):
                guard let retained = snapshot.retainedRange(range, in: updated),
                      NSIntersectionRange(retained, updated.selectedRange).length == 0 else { return false }
                if updated.hasSameText(as: snapshot) { snapshot = updated }
                return true
            case .typing:
                guard pendingEdit != .other else { return false }
                pendingEdit = .typing
                return true
            case let .deletion(backward):
                let caret = snapshot.selectedRange.location
                if backward ? (caret > range.location && caret <= NSMaxRange(range))
                    : (caret >= range.location && caret < NSMaxRange(range)) { return false }
                fallthrough
            case .input:
                // Multiple edits without a value observation can hide a remove-and-retype.
                guard pendingEdit == nil else { return false }
                pendingEdit = .other
                return true
            case .uncertain:
                return false
            }
        }
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
        var voiceOrigin: VoiceOrigin?

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
    private let observeVoiceTarget: () -> PassportVoiceTarget?
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
    private var voiceCommitWait: VoiceCommitWait?
    private var unresolvedCommitTarget: PassportVoiceTarget?
    private var earlyReturn: EarlyReturn?
    private var committedVoiceInput: CommittedVoiceInput?
    private var stopping = false

    init(
        makePlayback: @escaping (@escaping () -> Void) throws -> AudioPlayback,
        tapVoiceKey: (() throws -> Void)?,
        resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction,
        sendKey: @escaping (PassportKeystroke) throws -> Void = { _ in },
        observeVoiceTarget: @escaping () -> PassportVoiceTarget? = { nil },
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
        self.observeVoiceTarget = observeVoiceTarget
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
            voiceCommitWait = nil
            unresolvedCommitTarget = nil
            earlyReturn = nil
            committedVoiceInput = nil
            capture?.voiceOrigin = nil
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
        if let earlyReturn, now >= earlyReturn.deadline { self.earlyReturn = nil }
        checkVoiceCommit(now: now)
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
        voiceCommitWait = nil
        unresolvedCommitTarget = nil
        earlyReturn = nil
        committedVoiceInput = nil
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
            // Doubao provides no session ID for text arriving after its stop shortcut.
            // An expired Return can still leave an unresolved commit in the same field.
            let targetStillFocused = unresolvedCommitTarget?.isFocused == true
            if !targetStillFocused { unresolvedCommitTarget = nil }
            let canAttribute = voiceCommitWait?.stopShortcutSent != true && !targetStillFocused
            unresolvedCommitTarget?.stopMonitoringInput()
            voiceCommitWait = nil
            if earlyReturn?.id != id || !canAttribute { earlyReturn = nil }
            start(id: id, canAttribute: canAttribute, now: now)
        case "ptt_up":
            guard control.sessionId == capture?.id, let capture, capture.tail == nil,
                  capture.drainDeadline == nil, let final = control.finalSequence else { return }
            let finalFrame = final == UInt32.max ? -1 : Int(final)
            log("Passport session \(capture.id) stopped (finalSequence: \(finalFrame))")
            capture.tail = (finalFrame, now + .milliseconds(500))
            let origin = capture.voiceOrigin
            let queuedReturn = earlyReturn.map {
                $0.id == capture.id && now < $0.deadline && $0.origin?.isUnchanged == true
            } ?? false
            earlyReturn = nil
            voiceCommitWait = VoiceCommitWait(
                deadline: now + .seconds(5), origin: origin?.isUnchanged == true ? origin : nil,
                returnQueued: queuedReturn
            )
            statusChanged(.finishing)
            sendState("processing")
            flush(capture, now: now)
        case "button_event":
            guard isReady, let gesture = PassportGesture(button: control.button, event: control.event) else { return }
            let action = resolveAction(gesture)
            if let id = control.sessionId {
                handleReturnBeforeStop(action, sessionID: id, now: now)
            } else {
                perform(action)
            }
        case "device_error":
            if earlyReturn?.id == control.sessionId { earlyReturn = nil }
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

    private func handleReturnBeforeStop(_ action: PassportAction, sessionID id: UInt32, now: DispatchTime) {
        guard action == .returnKey, id != 0 else { return }
        if voiceCommitWait != nil, id == lastSessionID {
            perform(action)
            return
        }
        // During BLE link setup or final audio transmission, a gesture after
        // the physical UP can lead the worker's ptt_down or ptt_up notification.
        // It is eligible only if the same session subsequently ends normally.
        guard earlyReturn?.id != id else { return }
        let origin: VoiceOrigin?
        if let capture {
            guard capture.id == id, capture.tail == nil, capture.drainDeadline == nil else { return }
            origin = capture.voiceOrigin
        } else {
            guard id != lastSessionID else { return }
            origin = observeVoiceOrigin()
        }
        earlyReturn = EarlyReturn(id: id, deadline: now + .seconds(3), origin: origin)
    }

    private func perform(_ action: PassportAction) {
        if voiceCommitWait != nil {
            // The audio can be ready while Doubao is still editing. Keep direct
            // keystrokes out of that window even when attribution was lost.
            if action == .returnKey { voiceCommitWait?.returnQueued = true }
            return
        }
        guard capture == nil else { return }
        switch action {
        case .returnKey:
            sendKeystroke(.returnKey)
        case .backspace:
            sendKeystroke(.backspace)
        case let .shortcut(key, _):
            sendKeystroke(key)
        case .deleteVoiceInput:
            deleteVoiceInput()
        case .none:
            break
        }
    }

    private func sendKeystroke(_ key: PassportKeystroke) {
        do { try sendKey(key) }
        catch { log("Unable to send Passport keystroke: \(error.localizedDescription)") }
    }

    private func checkVoiceCommit(now: DispatchTime) {
        guard let wait = voiceCommitWait else { return }
        guard now < wait.deadline else {
            voiceCommitWait = nil
            unresolvedCommitTarget?.stopMonitoringInput()
            return
        }
        guard wait.stopShortcutSent, let origin = wait.origin else { return }
        guard let updated = origin.snapshot() else {
            voiceCommitWait?.origin = nil
            return
        }
        guard updated != origin.baseline else { return }
        guard let range = origin.baseline.insertedRange(in: updated) else {
            voiceCommitWait?.origin = nil
            return
        }
        voiceCommitWait = nil
        unresolvedCommitTarget = nil
        let committed = CommittedVoiceInput(target: origin.target, snapshot: updated, range: range)
        if origin.target.monitorEdits(ifSnapshotIs: updated, onEdit: { [weak self, weak committed] observation in
            guard let self, let committed, self.committedVoiceInput === committed else { return }
            if !committed.apply(observation) { self.committedVoiceInput = nil }
        }) {
            committedVoiceInput = committed
        }
        if wait.returnQueued {
            do { try origin.target.send(.returnKey, ifSnapshotIs: updated) }
            catch { log("Unable to send Passport keystroke: \(error.localizedDescription)") }
        }
    }

    private func deleteVoiceInput() {
        guard let committed = committedVoiceInput else { return }
        committedVoiceInput = nil
        guard !committed.inputPending else { return }
        do { try committed.target.delete(committed.range, ifSnapshotIs: committed.snapshot) }
        catch { log("Unable to delete Passport voice input: \(error.localizedDescription)") }
    }

    private func start(id: UInt32, canAttribute: Bool, now: DispatchTime) {
        lastSessionID = id
        let generation = UUID()
        let setupStarted = DispatchTime.now()
        do {
            let playback = try makePlayback { [weak self] in
                guard let self, self.capture?.generation == generation else { return }
                self.abort("BlackHole stopped during playback")
            }
            if let pending = earlyReturn,
               now >= pending.deadline || pending.origin?.isUnchanged != true { earlyReturn = nil }
            let origin = canAttribute ? (earlyReturn?.origin ?? observeVoiceOrigin()) : nil
            do {
                try tapVoiceKey?()
            } catch {
                playback.stop()
                throw error
            }
            committedVoiceInput = nil
            let setupTime = DispatchTime.now().uptimeNanoseconds - setupStarted.uptimeNanoseconds
            let started = now + .nanoseconds(Int(setupTime))
            let capture = Capture(id: id, generation: generation, playback: playback, now: started, leadTime: leadTime)
            capture.voiceOrigin = origin
            self.capture = capture
            log("Passport session \(id) started")
            statusChanged(.recording)
            tick(now: started)
        } catch {
            log("Unable to start Passport session \(id): \(error.localizedDescription)")
            resetPassport()
        }
    }

    private func observeVoiceOrigin() -> VoiceOrigin? {
        guard tapVoiceKey != nil, let target = observeVoiceTarget(), target.canConfirmVoiceText,
              let baseline = target.snapshot() else { return nil }
        return VoiceOrigin(target: target, baseline: baseline)
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
                self.closeCapture(endingNormally: capture.tail != nil)
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

    private func closeCapture(endingNormally: Bool = false) {
        guard let capture else { return }
        self.capture = nil
        capture.playback.stop()
        let canConfirmCommit = endingNormally && voiceCommitWait?.origin?.isUnchanged == true
        if !canConfirmCommit { voiceCommitWait?.origin = nil }
        do {
            if let tapVoiceKey {
                try tapVoiceKey()
                voiceCommitWait?.stopShortcutSent = true
                if let target = capture.voiceOrigin?.target { unresolvedCommitTarget = target }
                if voiceCommitWait == nil { unresolvedCommitTarget?.stopMonitoringInput() }
            }
        } catch {
            voiceCommitWait?.origin = nil
            log("Unable to end Doubao voice input: \(error.localizedDescription)")
        }
    }

    private func sendHandshake(repeatReady: Bool = false) {
        guard subscribed, helloValidated, capture == nil, readiness != .awaitingAcknowledgment,
              !isReady || repeatReady else { return }
        if !isReady { readiness = .awaitingAcknowledgment }
        send(HelperCommand(type: "host_ready", host: "passvoice"))
    }

    private func resetPassport() {
        earlyReturn = nil
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
