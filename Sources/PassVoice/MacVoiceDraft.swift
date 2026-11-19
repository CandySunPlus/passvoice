import AppKit
import Carbon.HIToolbox
import CoreAudio

// Doubao sees a standard, focused NSTextView for the whole voice session.
final class MacVoiceDraft: PassportVoiceDraft {
    private enum Dictation {
        case idle, starting, listening, unverified
    }

    private static let initialInputGrace: DispatchTimeInterval = .milliseconds(350)
    private static let retriedInputTimeout: DispatchTimeInterval = .milliseconds(750)

    private let target: MacInputTarget
    private let inputSourceID: String
    private let inputMethod: NSRunningApplication?
    private let panel: VoiceDraftPanel
    private var editor: NSTextView { panel.editor }
    private var dictation = Dictation.idle
    private var closed = false

    var isFocused: Bool {
        target.isFrontmost && panel.isKeyWindow && panel.firstResponder === editor
    }

    private var activeInputContext: NSTextInputContext? {
        guard isFocused, let context = editor.inputContext, NSTextInputContext.current === context else { return nil }
        return context
    }

    init() throws {
        try VoiceHotkey.checkAccess()
        guard let target = MacInputTarget.observe() else {
            throw BridgeError("Focus the input for your Passport voice draft and check Accessibility permission")
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let bundleID = Self.property(kTISPropertyBundleID, of: source),
              bundleID == "com.bytedance.inputmethod.doubaoime",
              let inputSourceID = Self.property(kTISPropertyInputSourceID, of: source) else {
            throw BridgeError("Select the Doubao input source before starting Passport voice input")
        }
        self.target = target
        self.inputSourceID = inputSourceID
        inputMethod = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        panel = VoiceDraftPanel()
    }

    func start(canRetry: @escaping () -> Bool, _ completion: @escaping (Result<Void, Error>) -> Void) {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
        // Check after AppKit has delivered the key-window transition to the input system.
        DispatchQueue.main.async { [weak self] in
            self?.beginWhenInputReady(until: .now() + .seconds(1), canRetry: canRetry, completion: completion)
        }
    }

    private func beginWhenInputReady(until deadline: DispatchTime, requestedSource: Bool = false,
                                     canRetry: @escaping () -> Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed else { return }
        var requestedSource = requestedSource
        if let context = activeInputContext {
            if context.selectedKeyboardInputSource == inputSourceID {
                do {
                    try startDictation(canRetry: canRetry, completion: completion)
                } catch {
                    completion(.failure(error))
                }
                return
            }
            if !requestedSource {
                context.selectedKeyboardInputSource = inputSourceID
                requestedSource = true
            }
        }

        if DispatchTime.now() >= deadline {
            let message = isFocused ? "The Passport draft could not activate the Doubao input context"
                                    : "Unable to focus the Passport voice draft"
            completion(.failure(BridgeError(message)))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
                self?.beginWhenInputReady(until: deadline, requestedSource: requestedSource,
                                          canRetry: canRetry, completion: completion)
            }
        }
    }

    private func startDictation(canRetry: @escaping () -> Bool,
                                completion: @escaping (Result<Void, Error>) -> Void) throws {
        let running = audioInputRunning
        guard running != true else {
            throw BridgeError("Stop the current Doubao dictation before starting Passport voice input")
        }
        try VoiceHotkey.tapRightOption()
        if running == nil {
            // Older macOS versions cannot report per-process audio input.
            dictation = .unverified
            reportListening(completion)
        } else {
            dictation = .starting
            waitForAudioInput(until: .now() + Self.initialInputGrace, canRetry: canRetry, completion: completion)
        }
    }

    private func waitForAudioInput(until deadline: DispatchTime, canRetry: (() -> Bool)?,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed else { return }
        guard activeInputContext?.selectedKeyboardInputSource == inputSourceID else {
            completion(.failure(BridgeError("The Passport voice draft lost the Doubao input context")))
            return
        }
        guard let running = audioInputRunning else {
            completion(.failure(BridgeError("Unable to verify that Doubao started receiving audio")))
            return
        }
        if running {
            dictation = .listening
            reportListening(completion)
        } else if DispatchTime.now() < deadline {
            let nextCheck = min(deadline, .now() + .milliseconds(40))
            DispatchQueue.main.asyncAfter(deadline: nextCheck) { [weak self] in
                self?.waitForAudioInput(until: deadline, canRetry: canRetry, completion: completion)
            }
        } else if canRetry?() == true {
            do {
                try VoiceHotkey.tapRightOption()
                waitForAudioInput(until: .now() + Self.retriedInputTimeout, canRetry: nil, completion: completion)
            } catch {
                completion(.failure(error))
            }
        } else {
            completion(.failure(BridgeError("Doubao did not start receiving Passport audio")))
        }
    }

    private func reportListening(_ completion: (Result<Void, Error>) -> Void) {
        panel.setPhase(.listening)
        completion(.success(()))
    }

    func finish(_ completion: @escaping (Result<PassportInputTarget?, Error>) -> Void) {
        do {
            _ = try stopListening()
        } catch {
            completion(.failure(error))
            return
        }
        panel.setPhase(.confirming)
        let now = DispatchTime.now()
        settle(previous: nil, changedAt: now, deadline: now + .seconds(4), completion: completion)
    }

    func cancel(_ completion: @escaping () -> Void) {
        let waitForStop = (try? stopListening()) == true
        closed = true
        if waitForStop {
            // Keep the draft as the IME client until the stop hotkey has been delivered.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                self.closePanel()
                completion()
            }
        } else {
            closePanel()
            completion()
        }
    }

    private func stopListening() throws -> Bool {
        guard dictation != .idle else { return false }
        guard activeInputContext?.selectedKeyboardInputSource == inputSourceID else {
            throw BridgeError("The Passport voice draft lost the Doubao input context")
        }
        let previous = dictation
        dictation = .idle
        // The same shortcut starts and stops Doubao. Sending it while idle would start recording.
        guard previous == .unverified || audioInputRunning == true else { return false }
        try VoiceHotkey.tapRightOption()
        return true
    }

    private func settle(previous: String?, changedAt: DispatchTime, deadline: DispatchTime,
                        completion: @escaping (Result<PassportInputTarget?, Error>) -> Void) {
        guard !closed else { return }
        guard isFocused else {
            completion(.failure(BridgeError("The Passport voice draft lost focus")))
            return
        }
        let now = DispatchTime.now()
        let current = editor.hasMarkedText() ? nil : editor.string
        let stableSince = current == previous ? changedAt : now
        if let current, now >= stableSince + .milliseconds(650) {
            // A newline or tab can be interpreted as a key by terminal programs.
            let singleLine = String(current.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            let text = String(singleLine.unicodeScalars.filter {
                $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
            })
            closePanel()
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                completion(.success(nil))
            } else {
                pasteWhenFocused(text, deadline: now + .milliseconds(900), completion: completion)
            }
        } else if now >= deadline {
            completion(.failure(BridgeError("Doubao did not finish the Passport voice draft")))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
                self?.settle(previous: current, changedAt: stableSince, deadline: deadline, completion: completion)
            }
        }
    }

    private func closePanel() {
        if let context = editor.inputContext, NSTextInputContext.current === context {
            context.discardMarkedText()
        }
        // Ordering out the non-activating panel releases its keyboard focus to the target.
        panel.orderOut(nil)
    }

    private func pasteWhenFocused(_ text: String, deadline: DispatchTime,
                                  completion: @escaping (Result<PassportInputTarget?, Error>) -> Void) {
        guard !closed else { return }
        if target.isFocused {
            do {
                try PassportDraftPaste.insert(text, into: target)
                // Give the target app time to consume the paste before a queued Return or Undo.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                    guard let self, !self.closed else { return }
                    completion(.success(self.target))
                }
            } catch {
                completion(.failure(error))
            }
        } else if DispatchTime.now() >= deadline {
            completion(.failure(BridgeError("Unable to restore the original Passport input")))
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
                self?.pasteWhenFocused(text, deadline: deadline, completion: completion)
            }
        }
    }

    private static func property(_ key: CFString, of source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private var audioInputRunning: Bool? {
        guard #available(macOS 14.2, *), let inputMethod, !inputMethod.isTerminated else { return nil }
        var pid = inputMethod.processIdentifier
        var process = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr else {
            return nil
        }
        if process == kAudioObjectUnknown { return false }

        address.mSelector = kAudioProcessPropertyIsRunningInput
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }
}
