import Foundation

struct PassportBridgeTests {
    func testDownClickSendsOneReturnWhileIdle() {
        let harness = Harness()
        harness.connect()
        harness.downClick()
        expectEqual(harness.keys, [.returnKey])
    }

    func testMissingTailFrameIsFilledWithSilenceAfterWaiting() {
        let harness = Harness()
        harness.connect()
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 2])
        harness.frame(session: 1, sequence: 2, sample: 32)
        harness.bridge.tick(now: harness.now + .milliseconds(499))
        expectNil(harness.outputs[0].completion)
        harness.bridge.tick(now: harness.now + .milliseconds(501))
        expectEqual(harness.outputs[0].samples, [12, 0, 32])
        expectNotNil(harness.outputs[0].completion)
    }

    func testHelperDeliversShortHandshakeBeforeWaitingForReply() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("passport-fixture")
        try """
        #!/bin/sh
        printf '%s\\n' '{"type":"subscribed"}'
        IFS= read -r command
        case "$command" in
            *host_ready*) exit 0 ;;
        esac
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let helper = HelperProcess(executable: executable)
        var exitStatus: Int32?
        try helper.start(onEvent: { event in
            expectEqual(event.type, "subscribed")
            try! helper.send(HelperCommand(type: "host_ready"))
        }, onExit: { exitStatus = $0 })
        let deadline = Date().addingTimeInterval(3)
        while exitStatus == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        helper.stop()
        expectEqual(exitStatus, 0)
    }

    func testSavedDeleteVoiceBindingIsMigratedToUndo() {
        let suite = "PassVoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bindings = PassportButtonBindings(defaults: defaults)
        bindings.set(.deleteVoiceInput, for: .okLong)
        expectEqual(bindings.action(for: .okLong), .undo)
    }

    func testChangingEachBindingTakesEffectOnTheCurrentBridge() {
        let suite = "PassVoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bindings = PassportButtonBindings(defaults: defaults)
        let harness = Harness(resolveAction: bindings.action(for:))
        harness.connect()

        let shiftReturn = PassportKeystroke(keyCode: 36, modifiers: [.shift])
        bindings.set(.backspace, for: .downClick)
        bindings.set(.shortcut(shiftReturn, keyName: "↩"), for: .downLong)
        bindings.set(.none, for: .okClick)
        bindings.set(.returnKey, for: .okLong)
        harness.downClick()
        harness.downLong()
        harness.control(["type": "button_event", "button": "ok", "event": "click"])
        harness.okLong()
        expectEqual(harness.keys, [.backspace, shiftReturn, .returnKey])
    }

    func testSavedShortcutSendsItsKeyAndModifiersAfterReloadingBindings() {
        let suite = "PassVoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bindings = PassportButtonBindings(defaults: defaults)
        bindings.set(.shortcut(PassportKeystroke(keyCode: 36, modifiers: [.shift]), keyName: "↩"), for: .downLong)

        let reloaded = PassportButtonBindings(defaults: UserDefaults(suiteName: suite)!)
        let harness = Harness(resolveAction: reloaded.action(for:))
        harness.connect()
        harness.downLong()
        expectEqual(harness.keys.map(\.keyCode), [36])
        expectEqual(harness.keys.map(\.modifiers), [.shift])
    }

    func testOkClickSendsOneBackspaceWhileIdle() {
        let harness = Harness()
        harness.connect()
        harness.control(["type": "button_event", "button": "ok", "event": "click"])
        expectEqual(harness.keys.map(\.keyCode), [51]) // macOS Delete (Backspace)
    }

    func testFinishWaitsForInclusiveTailAndBlackHoleDrainBeforeAllowingAnotherSession() {
        let harness = Harness()
        harness.event("connected")
        harness.control(Self.hello)
        expectEqual(harness.commands, [])
        harness.event("subscribed")
        harness.control(Self.hello)
        expectEqual(harness.commands, ["host_ready"])
        expectEqual(harness.handshakeHost, "passvoice")
        expectEqual(harness.statuses, [.handshaking])
        harness.control(["type": "ptt_down", "sessionId": 1])
        expectEqual(harness.outputs.count, 0)
        harness.event("host_ready_ack")
        expectEqual(harness.statuses.last, .ready)

        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 2])
        expectEqual(harness.statuses.last, .finishing)
        harness.frame(session: 1, sequence: 2, sample: 32)
        expectEqual(harness.outputs[0].samples, [12])
        expectNil(harness.outputs[0].completion)
        harness.frame(session: 1, sequence: 1, sample: 22)
        expectEqual(harness.outputs[0].samples, [12, 22, 32])
        expectEqual(harness.commands, ["host_ready", "processing"])
        expectEqual(harness.drafts.count, 1)

        harness.outputs[0].completeDrain()
        expectEqual(harness.commands.last, "processing")
        harness.control(["type": "ptt_down", "sessionId": 2])
        expectEqual(harness.outputs.count, 1)
        harness.drafts[0].complete()
        expectEqual(harness.commands.last, "ready")
        expectEqual(harness.statuses.last, .ready)
        expectTrue(harness.outputs[0].stopped)

        harness.control(["type": "ptt_down", "sessionId": 2])
        harness.control(["type": "ptt_up", "sessionId": 2, "finalSequence": UInt32.max])
        expectEqual(harness.outputs.count, 2)
        expectEqual(harness.outputs[1].samples, [])
        harness.outputs[1].completeDrain()
        harness.drafts[1].complete()
        expectEqual(harness.commands.last, "ready")
    }

    func testReconnectWaitsForDisconnectedCaptureToDrainAndCanReuseSessionID() {
        let harness = Harness(automatic: false)
        harness.connect()
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.event("disconnected")
        expectEqual(harness.statuses.last, .disconnected)
        harness.event("connected")
        harness.event("subscribed")
        harness.control(Self.hello)
        expectEqual(harness.commands, ["host_ready"])
        expectEqual(harness.outputs[0].samples, [12])
        harness.outputs[0].completeDrain()
        expectEqual(harness.commands, ["host_ready", "host_ready"])
        expectEqual(harness.statuses.last, .handshaking)
        harness.event("host_ready_ack")

        harness.control(["type": "ptt_down", "sessionId": 1])
        expectEqual(harness.outputs.count, 2)
    }

    func testRestoringDefaultsClearsAllSavedBindings() {
        let suite = "PassVoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bindings = PassportButtonBindings(defaults: defaults)
        bindings.set(.none, for: .downClick)
        bindings.set(.returnKey, for: .downLong)
        bindings.set(.none, for: .okClick)
        bindings.set(.none, for: .okLong)
        let reloaded = PassportButtonBindings(defaults: UserDefaults(suiteName: suite)!)
        let harness = Harness(resolveAction: reloaded.action(for:))
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.drafts[0].complete()

        bindings.restoreDefaults()
        harness.downClick()
        harness.downLong()
        harness.control(["type": "button_event", "button": "ok", "event": "click"])
        harness.okLong()
        expectEqual(harness.keys, [.returnKey, .backspace, .undo])
    }

    func testDownLongDoesNotSendOrQueueItsBindingDuringCapture() {
        let harness = Harness(resolveAction: { gesture in
            gesture == .downLong ? .returnKey : PassportAction.defaultAction(for: gesture)
        })
        harness.startVoiceCapture()
        harness.downLong()
        expectEqual(harness.keys, [])

        harness.finishVoiceCapture()
        harness.drafts[0].complete()
        expectEqual(harness.keys, [])

        harness.downLong()
        expectEqual(harness.keys, [.returnKey])
    }

    func testCustomReturnIsIgnoredWhileRecordingAndNeverDeferred() {
        let harness = Harness(resolveAction: { _ in .shortcut(.returnKey, keyName: "↩") })
        harness.startVoiceCapture()
        harness.downClick()
        harness.control(["type": "button_event", "button": "down", "event": "click", "sessionId": 1])
        harness.finishVoiceCapture()
        harness.downClick()
        harness.drafts[0].complete()
        expectEqual(harness.keys, [])

        harness.downClick()
        expectEqual(harness.keys, [.returnKey])
    }

    func testConfirmWritesTheDraftAfterTheAudioDrains() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.drafts[0].text = "语音"
        expectEqual(harness.target.text, "A")
        harness.stopVoiceCapture()
        expectEqual(harness.target.text, "A")
        harness.outputs[0].completeDrain()
        expectEqual(harness.target.text, "A")
        harness.drafts[0].complete()
        expectEqual(harness.target.text, "A语音")
        expectEqual(harness.keys, [])
        expectEqual(harness.commands.last, "ready")

        harness.okLong()
        expectEqual(harness.keys, [.undo])
    }

    func testCancelDiscardsTheDraftAndWaitsForTheInputMethodBeforeReady() {
        let harness = Harness()
        harness.startVoiceCapture()
        let draft = harness.drafts[0]
        draft.text = "语音"
        expectEqual(harness.target.text, "A")
        harness.control(["type": "ptt_cancel", "sessionId": 1])
        expectTrue(harness.outputs[0].stopped)
        expectEqual(draft.cancelCount, 1)
        expectEqual(draft.text, "")
        expectEqual(harness.target.text, "A")
        expectEqual(harness.keys, [])

        harness.startVoiceCapture(session: 2)
        expectEqual(harness.drafts.count, 1)
        draft.completeCancellation()
        expectEqual(harness.commands.last, "ready")
        expectEqual(harness.statuses.last, .ready)

        harness.startVoiceCapture(session: 2)
        expectEqual(harness.drafts.count, 2)
    }

    func testCancelWhileOpeningIgnoresTheDelayedStart() {
        let harness = Harness(delayStart: true)
        harness.startVoiceCapture()
        expectEqual(harness.outputs[0].samples, [])
        harness.control(["type": "ptt_cancel", "sessionId": 1])
        harness.drafts[0].completeStart()
        harness.drafts[0].completeCancellation()
        expectEqual(harness.outputs[0].samples, [])
        expectEqual(harness.commands.last, "ready")
    }

    func testStaleCancelCannotDiscardAConfirmedOrDifferentDraft() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.control(["type": "ptt_cancel", "sessionId": 2])
        harness.finishVoiceCapture()
        harness.control(["type": "ptt_cancel", "sessionId": 1])
        expectEqual(harness.drafts[0].cancelCount, 0)
        harness.drafts[0].complete()
        expectEqual(harness.target.text, "AB")
    }

    func testDownPressedDuringFinalizationSendsOneReturnAfterPaste() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.downClick()
        expectEqual(harness.keys, [])
        harness.stopVoiceCapture()
        harness.downClick()
        harness.taggedDown(session: 1)
        harness.outputs[0].completeDrain()
        expectEqual(harness.keys, [])
        harness.drafts[0].complete()
        harness.taggedDown(session: 1)
        expectEqual(harness.target.text, "AB")
        expectEqual(harness.keys, [.returnKey])
    }

    func testFirstTaggedDownCanArriveAfterPaste() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.drafts[0].complete()
        harness.taggedDown(session: 1)
        harness.taggedDown(session: 1)
        expectEqual(harness.keys, [.returnKey])
    }

    func testTaggedDownCanArriveBeforePttUpOrPttDown() {
        for beforeCapture in [true, false] {
            let harness = Harness()
            harness.connect()
            if beforeCapture { harness.taggedDown(session: 1) }
            harness.startVoiceCapture()
            if !beforeCapture { harness.taggedDown(session: 1) }
            harness.finishVoiceCapture()
            expectEqual(harness.keys, [])
            harness.drafts[0].complete()
            expectEqual(harness.keys, [.returnKey])
        }
    }

    func testTaggedDownCannotFollowNewFocusOrDifferentSession() {
        for nextSession: UInt32 in [1, 2] {
            let harness = Harness()
            harness.connect()
            harness.taggedDown(session: 1)
            if nextSession == 1 { harness.target.isFocused = false }
            harness.startVoiceCapture(session: nextSession)
            harness.finishVoiceCapture(session: nextSession)
            harness.drafts[0].complete()
            expectEqual(harness.keys, [])
        }
    }

    func testUndoPressedDuringFinalizationWaitsForPasteAndKeepsFocus() {
        for sameFocus in [true, false] {
            let harness = Harness()
            harness.startVoiceCapture()
            harness.stopVoiceCapture()
            harness.downClick()
            harness.okLong()
            harness.okLong()
            harness.outputs[0].completeDrain()
            expectEqual(harness.keys, [])
            harness.drafts[0].complete(focusAfterPaste: sameFocus)
            expectEqual(harness.keys, sameFocus ? [.undo] : [])
        }
    }

    func testEmptyOrUnrestoredDraftDoesNotSendQueuedKeys() {
        for hasText in [true, false] {
            let harness = Harness()
            harness.startVoiceCapture()
            if !hasText { harness.drafts[0].text = "" }
            harness.stopVoiceCapture()
            harness.downClick()
            harness.outputs[0].completeDrain()
            harness.drafts[0].complete(restored: !hasText)
            if hasText { harness.drafts[0].completeCancellation() }
            expectEqual(harness.target.text, "A")
            expectEqual(harness.keys, [])
            expectEqual(harness.commands.last, "ready")
        }
    }

    func testDisconnectDiscardsTheDraftAndLateCompletion() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.event("disconnected")
        harness.connect()
        harness.drafts[0].complete()
        expectEqual(harness.target.text, "A")
        expectEqual(harness.keys, [])
        harness.drafts[0].completeCancellation()
        harness.event("host_ready_ack")
        harness.startVoiceCapture()
        expectEqual(harness.drafts.count, 2)
    }

    func testOkClickDoesNotEditTheTargetWhileTheDraftIsOpen() {
        let harness = Harness()
        let shortOK = ["type": "button_event", "button": "ok", "event": "click"]
        harness.startVoiceCapture()
        harness.control(shortOK)
        harness.finishVoiceCapture()
        harness.control(shortOK)
        harness.drafts[0].complete()
        expectEqual(harness.keys, [])
        harness.control(shortOK)
        expectEqual(harness.keys, [.backspace])
    }

    private static let hello: [String: Any] = [
        "type": "hello", "device": "ai-passport", "codec": "ima-adpcm",
        "sampleRate": 16000, "channels": 1, "frameMs": 20,
    ]

    private final class Harness {
        let now = DispatchTime.now()
        private let resolveAction: (PassportGesture) -> PassportAction
        private let automatic: Bool
        private let delayStart: Bool
        private(set) var commands: [String] = []
        private(set) var handshakeHost: String?
        private(set) var outputs: [Playback] = []
        private(set) var drafts: [Draft] = []
        private(set) var keys: [PassportKeystroke] = []
        private(set) var statuses: [PassportStatus] = []
        lazy var target = Target { [unowned self] key in keys.append(key) }
        lazy var bridge = PassportBridge(
            makePlayback: { [unowned self] _ in
                let output = Playback()
                outputs.append(output)
                return output
            },
            makeDraft: automatic ? { [unowned self] in
                let draft = Draft(target: target, delayStart: delayStart)
                drafts.append(draft)
                return draft
            } : nil,
            resolveAction: resolveAction,
            sendKey: { [unowned self] key in keys.append(key) },
            observeInputTarget: { [unowned self] in target },
            send: { [unowned self] command in
                commands.append(command.state ?? command.type)
                if command.type == "host_ready" {
                    handshakeHost = command.host
                    expectEqual(command.cancelVoice, automatic ? true : nil)
                }
            },
            log: { _ in },
            statusChanged: { [unowned self] status in statuses.append(status) },
            leadTime: .nanoseconds(0)
        )

        init(automatic: Bool = true, delayStart: Bool = false,
             resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction) {
            self.automatic = automatic
            self.delayStart = delayStart
            self.resolveAction = resolveAction
        }

        func connect() {
            if commands.isEmpty || statuses.last == .disconnected {
                event("connected")
                event("subscribed")
                control(PassportBridgeTests.hello)
                event("host_ready_ack")
            }
        }

        func downClick() {
            control(["type": "button_event", "button": "down", "event": "click"])
        }

        func taggedDown(session: UInt32) {
            control(["type": "button_event", "button": "down", "event": "click", "sessionId": session])
        }

        func downLong() {
            control(["type": "button_event", "button": "down", "event": "long"])
        }

        func okLong() {
            control(["type": "button_event", "button": "ok", "event": "long"])
        }

        func startVoiceCapture(session: UInt32 = 1) {
            connect()
            control(["type": "ptt_down", "sessionId": session])
            frame(session: session, sequence: 0, sample: 12)
        }

        func stopVoiceCapture(session: UInt32 = 1) {
            control(["type": "ptt_up", "sessionId": session, "finalSequence": 0])
        }

        func finishVoiceCapture(session: UInt32 = 1) {
            stopVoiceCapture(session: session)
            outputs.last?.completeDrain()
        }

        func control(_ fields: [String: Any]) {
            var payload = fields
            payload["v"] = 1
            let data = try! JSONSerialization.data(withJSONObject: payload)
            event("control", fields: ["payloadBase64": data.base64EncodedString()])
        }

        func frame(session: UInt32, sequence: UInt32, sample: UInt8) {
            var bytes = [UInt8](repeating: 0, count: 166)
            bytes[0] = sample
            bytes[3] = 64
            bytes[4] = 1
            event("audio", fields: [
                "sessionId": session, "sequence": sequence, "payloadBase64": Data(bytes).base64EncodedString(),
            ])
        }

        func event(_ type: String, fields: [String: Any] = [:]) {
            var object = fields
            object["type"] = type
            let data = try! JSONSerialization.data(withJSONObject: object)
            bridge.receive(try! JSONDecoder().decode(HelperEvent.self, from: data), now: now)
        }
    }

    private final class Target: PassportInputTarget {
        var text = "A"
        var isFocused = true
        let sendKey: (PassportKeystroke) -> Void

        init(_ sendKey: @escaping (PassportKeystroke) -> Void) {
            self.sendKey = sendKey
        }

        func send(_ key: PassportKeystroke) { sendKey(key) }
    }

    private final class Draft: PassportVoiceDraft {
        let target: Target
        let delayStart: Bool
        var text = "B"
        var isFocused = true
        private(set) var cancelCount = 0
        private var startCompletion: ((Result<Void, Error>) -> Void)?
        private var finishCompletion: ((Result<PassportInputTarget?, Error>) -> Void)?
        private var cancelCompletion: (() -> Void)?

        init(target: Target, delayStart: Bool) {
            self.target = target
            self.delayStart = delayStart
        }

        func start(_ completion: @escaping (Result<Void, Error>) -> Void) {
            startCompletion = completion
            if !delayStart { completeStart() }
        }

        func completeStart() {
            let callback = startCompletion
            startCompletion = nil
            callback?(.success(()))
        }

        func finish(_ completion: @escaping (Result<PassportInputTarget?, Error>) -> Void) {
            finishCompletion = completion
        }

        func complete(restored: Bool = true, focusAfterPaste: Bool = true) {
            guard let callback = finishCompletion else { return }
            finishCompletion = nil
            if !restored {
                callback(.failure(BridgeError("Test target lost focus")))
            } else if text.isEmpty {
                callback(.success(nil))
            } else {
                target.text += text
                target.isFocused = focusAfterPaste
                callback(.success(target))
            }
        }

        func cancel(_ completion: @escaping () -> Void) {
            cancelCount += 1
            text = ""
            cancelCompletion = completion
        }

        func completeCancellation() {
            let callback = cancelCompletion
            cancelCompletion = nil
            callback?()
        }
    }

    private final class Playback: AudioPlayback {
        var samples: [Int16] = []
        var completion: (() -> Void)?
        var stopped = false

        func enqueue(_ samples: [Int16]) { self.samples.append(samples[0]) }
        func play() {}
        func drain(_ completed: @escaping () -> Void) { completion = completed }
        func stop() { stopped = true }

        func completeDrain() {
            let callback = completion
            completion = nil
            callback?()
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    precondition(actual == expected, "Line \(line): expected \(expected), got \(actual)")
}

private func expectNil<T>(_ actual: T?, line: UInt = #line) {
    precondition(actual == nil, "Line \(line): expected nil")
}

private func expectNotNil<T>(_ actual: T?, line: UInt = #line) {
    precondition(actual != nil, "Line \(line): expected a value")
}

private func expectTrue(_ actual: Bool, line: UInt = #line) {
    precondition(actual, "Line \(line): expected true")
}

let tests = PassportBridgeTests()
tests.testDownClickSendsOneReturnWhileIdle()
tests.testMissingTailFrameIsFilledWithSilenceAfterWaiting()
try tests.testHelperDeliversShortHandshakeBeforeWaitingForReply()
tests.testSavedDeleteVoiceBindingIsMigratedToUndo()
tests.testChangingEachBindingTakesEffectOnTheCurrentBridge()
tests.testSavedShortcutSendsItsKeyAndModifiersAfterReloadingBindings()
tests.testOkClickSendsOneBackspaceWhileIdle()
tests.testFinishWaitsForInclusiveTailAndBlackHoleDrainBeforeAllowingAnotherSession()
tests.testReconnectWaitsForDisconnectedCaptureToDrainAndCanReuseSessionID()
tests.testRestoringDefaultsClearsAllSavedBindings()
tests.testDownLongDoesNotSendOrQueueItsBindingDuringCapture()
tests.testCustomReturnIsIgnoredWhileRecordingAndNeverDeferred()
tests.testConfirmWritesTheDraftAfterTheAudioDrains()
tests.testCancelDiscardsTheDraftAndWaitsForTheInputMethodBeforeReady()
tests.testCancelWhileOpeningIgnoresTheDelayedStart()
tests.testStaleCancelCannotDiscardAConfirmedOrDifferentDraft()
tests.testDownPressedDuringFinalizationSendsOneReturnAfterPaste()
tests.testFirstTaggedDownCanArriveAfterPaste()
tests.testTaggedDownCanArriveBeforePttUpOrPttDown()
tests.testTaggedDownCannotFollowNewFocusOrDifferentSession()
tests.testUndoPressedDuringFinalizationWaitsForPasteAndKeepsFocus()
tests.testEmptyOrUnrestoredDraftDoesNotSendQueuedKeys()
tests.testDisconnectDiscardsTheDraftAndLateCompletion()
tests.testOkClickDoesNotEditTheTargetWhileTheDraftIsOpen()
print("24 Passport bridge tests passed")
