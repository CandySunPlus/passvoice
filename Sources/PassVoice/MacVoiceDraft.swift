import AppKit
import Carbon.HIToolbox

// Doubao sees a standard, focused NSTextView for the whole voice session.
final class MacVoiceDraft: PassportVoiceDraft {
    private let target: MacInputTarget
    private let inputSourceID: String
    private let panel: VoiceDraftPanel
    private var editor: NSTextView { panel.editor }
    private var listening = false
    private var closed = false

    var isFocused: Bool {
        target.isFrontmost && panel.isKeyWindow && panel.firstResponder === editor
    }

    init() throws {
        try VoiceHotkey.checkAccess()
        guard let target = MacInputTarget.observe() else {
            throw BridgeError("Focus the input for your Passport voice draft and check Accessibility permission")
        }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.property(kTISPropertyBundleID, of: source) == "com.bytedance.inputmethod.doubaoime",
              let inputSourceID = Self.property(kTISPropertyInputSourceID, of: source) else {
            throw BridgeError("Select the Doubao input source before starting Passport voice input")
        }
        self.target = target
        self.inputSourceID = inputSourceID
        panel = VoiceDraftPanel()
    }

    func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
        // Check after AppKit has delivered the key-window transition to the input system.
        DispatchQueue.main.async { [weak self] in
            self?.beginWhenInputReady(until: .now() + .seconds(1), completion: completion)
        }
    }

    private func beginWhenInputReady(until deadline: DispatchTime, requestedSource: Bool = false,
                                     completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed else { return }
        var requestedSource = requestedSource
        if isFocused, let context = editor.inputContext, NSTextInputContext.current === context {
            if context.selectedKeyboardInputSource == inputSourceID {
                do {
                    try VoiceHotkey.tapRightOption()
                    listening = true
                    panel.setPhase(.listening)
                    completion(.success(()))
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
                self?.beginWhenInputReady(until: deadline, requestedSource: requestedSource, completion: completion)
            }
        }
    }

    func finish(_ completion: @escaping (Result<PassportInputTarget?, Error>) -> Void) {
        do {
            try stopListening()
        } catch {
            completion(.failure(error))
            return
        }
        panel.setPhase(.confirming)
        let now = DispatchTime.now()
        settle(previous: nil, changedAt: now, deadline: now + .seconds(4), completion: completion)
    }

    func cancel(_ completion: @escaping () -> Void) {
        let waitForStop = listening && isFocused
        try? stopListening()
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

    private func stopListening() throws {
        guard isFocused else { throw BridgeError("The Passport voice draft lost focus") }
        guard listening else { return }
        try VoiceHotkey.tapRightOption()
        listening = false
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
}
