import Foundation

struct PassportBridgeTests {
    func testDownClickSendsOneReturnWhileIdle() {
        let harness = Harness()
        harness.connect()
        harness.downClick()
        expectEqual(harness.keys, [.returnKey])
    }

    func testDownDuringRecordingIsIgnoredAndQueuedReturnsWaitForVoiceText() {
        let harness = Harness()
        harness.connect()
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.downClick()
        expectEqual(harness.keys, [])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 1])
        harness.downClick()
        harness.downClick()
        expectEqual(harness.keys, [])

        harness.frame(session: 1, sequence: 1, sample: 22)
        expectEqual(harness.keys, [])
        harness.outputs[0].completeDrain()
        harness.bridge.tick(now: harness.now + .milliseconds(100))
        expectEqual(harness.keys, [])

        harness.input.text = "A你好Z"
        harness.input.selection = NSRange(location: 3, length: 0)
        harness.bridge.tick(now: harness.now + .milliseconds(200))
        harness.bridge.tick(now: harness.now + .milliseconds(300))
        expectEqual(harness.keys, [.returnKey])
    }

    func testQueuedReturnIsDroppedIfInputChangesBeforeUpStopsRecording() {
        let harness = Harness()
        harness.connect()
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.input.text = "A异Z"
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 0])
        harness.downClick()
        harness.input.text = "A🙂Z"
        harness.outputs[0].completeDrain()
        harness.input.text = "A你好Z"
        harness.input.selection = NSRange(location: 3, length: 0)
        harness.bridge.tick(now: harness.now + .milliseconds(100))
        expectEqual(harness.keys, [])
    }

    func testQueuedReturnIsDroppedAfterLosingAndRegainingFocus() {
        let harness = Harness()
        harness.stopVoiceSessionWithQueuedReturn()
        harness.input.hasFocus = false
        harness.bridge.tick(now: harness.now + .milliseconds(100))

        harness.input.hasFocus = true
        harness.input.receiveVoiceText()
        harness.bridge.tick(now: harness.now + .milliseconds(200))
        expectEqual(harness.keys, [])
    }

    func testQueuedReturnIsDroppedWhenAnotherInputCouldHaveInsertedTheText() {
        let harness = Harness()
        harness.stopVoiceSessionWithQueuedReturn()
        harness.input.canConfirmVoiceText = false
        harness.input.receiveVoiceText()
        harness.bridge.tick(now: harness.now + .milliseconds(100))
        expectEqual(harness.keys, [])
    }

    func testQueuedReturnExpiresBeforeALateCommitAndNewPressWorks() {
        let harness = Harness()
        harness.stopVoiceSessionWithQueuedReturn()
        harness.input.receiveVoiceText()
        harness.bridge.tick(now: harness.now + .seconds(5))
        expectEqual(harness.keys, [])

        harness.downClick()
        expectEqual(harness.keys, [.returnKey])
    }

    func testOKLongDeletesCommittedVoiceTextAndKeepsLaterTyping() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("A说🙂", caret: 4)
        harness.input.setText("A说🙂C", caret: 5)
        harness.input.canConfirmVoiceText = false
        harness.okLong()
        expectEqual(harness.input.text, "AC")
    }

    func testOKLongKeepsTypingInsertedBeforeTheCommittedRange() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
        harness.input.setText("ACB", caret: 2)
        harness.okLong()
        expectEqual(harness.input.text, "AC")
    }

    func testOKLongSkipsWhenRepeatedTextMakesTheRangeAmbiguous() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
        harness.input.setText("ABB", caret: 3)
        harness.okLong()
        expectEqual(harness.input.text, "ABB")
    }

    func testOKLongSkipsWhenTheVoiceTextMayHaveAlreadyBeenRemoved() {
        let harness = Harness()
        harness.startVoiceCapture(text: "B")
        harness.finishVoiceCapture()
        harness.commitVoiceText("BB", caret: 2)
        harness.input.setText("B", caret: 1)
        harness.okLong()
        expectEqual(harness.input.text, "B")
    }

    func testOKLongSkipsTheNewlyFocusedInput() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
        let original = harness.input
        original.hasFocus = false
        harness.input = VoiceTarget(sendKey: { _ in })
        harness.input.setText("AB", caret: 2)
        harness.okLong()
        expectEqual(original.text, "AB")
        expectEqual(harness.input.text, "AB")
    }

    func testOKLongSkipsWhenTheSelectionCannotBeRead() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
        harness.input.selection = NSRange(location: NSNotFound, length: 0)
        harness.okLong()
        expectEqual(harness.input.text, "AB")
    }

    func testOKLongDoesNotDeleteVoiceTextAgainAfterTheFirstDeletion() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
        harness.okLong()
        expectEqual(harness.input.text, "A")

        harness.input.setText("AB", caret: 2)
        harness.okLong()
        expectEqual(harness.input.text, "AB")
    }

    func testOKLongDuringRecordingAndCommitWaitDoesNotQueueDeletion() {
        let harness = Harness()
        harness.startVoiceCapture()
        harness.okLong()
        harness.finishVoiceCapture()
        harness.okLong()
        harness.commitVoiceText("AB", caret: 2)
        expectEqual(harness.input.text, "AB")
    }

    func testOKLongCanDeleteTheCommitAlsoUsedForQueuedReturn() {
        let harness = Harness()
        harness.stopVoiceSessionWithQueuedReturn()
        harness.commitVoiceText("A你好Z", caret: 3)
        expectEqual(harness.keys, [.returnKey])
        harness.okLong()
        expectEqual(harness.input.text, "AZ")
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
        expectEqual(harness.taps, 1)

        harness.outputs[0].completeDrain()
        expectEqual(harness.commands.last, "ready")
        expectEqual(harness.statuses.last, .ready)
        expectEqual(harness.taps, 2)
        expectTrue(harness.outputs[0].stopped)

        harness.control(["type": "ptt_down", "sessionId": 2])
        harness.control(["type": "ptt_up", "sessionId": 2, "finalSequence": UInt32.max])
        expectEqual(harness.outputs.count, 2)
        expectEqual(harness.outputs[1].samples, [])
        harness.outputs[1].completeDrain()
        expectEqual(harness.taps, 4)
        expectEqual(harness.commands.last, "ready")
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

    func testReconnectWaitsForDisconnectedCaptureToDrainAndCanReuseSessionID() {
        let harness = Harness()
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
        expectEqual(harness.taps, 2)
        expectEqual(harness.statuses.last, .handshaking)
        harness.event("host_ready_ack")

        harness.control(["type": "ptt_down", "sessionId": 1])
        expectEqual(harness.outputs.count, 2)
        expectEqual(harness.taps, 3)
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

    private static let hello: [String: Any] = [
        "type": "hello", "device": "ai-passport", "codec": "ima-adpcm",
        "sampleRate": 16000, "channels": 1, "frameMs": 20,
    ]

    private final class Harness {
        let now = DispatchTime.now()
        private let resolveAction: (PassportGesture) -> PassportAction
        private(set) var commands: [String] = []
        private(set) var handshakeHost: String?
        private(set) var outputs: [Playback] = []
        private(set) var taps = 0
        private(set) var keys: [PassportKeystroke] = []
        lazy var input = VoiceTarget(sendKey: { [unowned self] key in keys.append(key) })
        private(set) var statuses: [PassportStatus] = []
        lazy var bridge = PassportBridge(
            makePlayback: { [unowned self] _ in
                let output = Playback()
                outputs.append(output)
                return output
            },
            tapVoiceKey: { [unowned self] in taps += 1 },
            resolveAction: resolveAction,
            sendKey: { [unowned self] key in keys.append(key) },
            observeVoiceTarget: { [unowned self] in input },
            send: { [unowned self] command in
                commands.append(command.state ?? command.type)
                if command.type == "host_ready" { handshakeHost = command.host }
            },
            log: { _ in },
            statusChanged: { [unowned self] status in statuses.append(status) },
            leadTime: .nanoseconds(0)
        )

        init(resolveAction: @escaping (PassportGesture) -> PassportAction = PassportAction.defaultAction) {
            self.resolveAction = resolveAction
        }

        func connect() {
            event("connected")
            event("subscribed")
            control(PassportBridgeTests.hello)
            event("host_ready_ack")
        }

        func downClick() {
            control(["type": "button_event", "button": "down", "event": "click", "durationMs": 0, "seq": 2])
        }

        func downLong() {
            control(["type": "button_event", "button": "down", "event": "long", "durationMs": 650])
        }

        func stopVoiceSessionWithQueuedReturn() {
            connect()
            control(["type": "ptt_down", "sessionId": 1])
            frame(session: 1, sequence: 0, sample: 12)
            control(["type": "ptt_up", "sessionId": 1, "finalSequence": 0])
            downClick()
            outputs[0].completeDrain()
        }

        func okLong() {
            control(["type": "button_event", "button": "ok", "event": "long"])
        }

        func startVoiceCapture(text: String = "A") {
            connect()
            input.setText(text, caret: text.utf16.count)
            control(["type": "ptt_down", "sessionId": 1])
            frame(session: 1, sequence: 0, sample: 12)
        }

        func finishVoiceCapture() {
            control(["type": "ptt_up", "sessionId": 1, "finalSequence": 0])
            outputs[0].completeDrain()
        }

        func commitVoiceText(_ text: String, caret: Int) {
            input.setText(text, caret: caret)
            bridge.tick(now: now + .milliseconds(100))
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

    private final class VoiceTarget: PassportVoiceTarget {
        var text = "A🙂Z"
        var selection = NSRange(location: 1, length: 2)
        var canConfirmVoiceText = true
        var hasFocus = true
        let sendKey: (PassportKeystroke) -> Void

        init(sendKey: @escaping (PassportKeystroke) -> Void) { self.sendKey = sendKey }

        func receiveVoiceText() {
            text = "A你好Z"
            selection = NSRange(location: 3, length: 0)
        }

        func snapshot() -> PassportTextState? {
            hasFocus ? PassportTextState(text: text, selectedRange: selection) : nil
        }

        func finishCommitObservation() {}

        func setText(_ text: String, caret: Int) {
            self.text = text
            selection = NSRange(location: caret, length: 0)
        }

        func delete(_ range: NSRange, ifSnapshotIs expected: PassportTextState) {
            guard snapshot() == expected, let indices = Range(range, in: text) else { return }
            text.removeSubrange(indices)
            selection = NSRange(location: range.location, length: 0)
        }

        func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) {
            if canConfirmVoiceText, snapshot() == expected { sendKey(key) }
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

extension PassportBridgeTests {
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
        harness.commitVoiceText("AB", caret: 2)

        bindings.restoreDefaults()
        harness.downClick()
        harness.downLong()
        harness.control(["type": "button_event", "button": "ok", "event": "click"])
        harness.okLong()
        expectEqual(harness.keys, [.returnKey, .backspace])
        expectEqual(harness.input.text, "A")
    }

    func testDownLongDoesNotSendOrQueueItsBindingDuringCapture() {
        let harness = Harness(resolveAction: { gesture in
            gesture == .downLong ? .returnKey : PassportAction.defaultAction(for: gesture)
        })
        harness.startVoiceCapture()
        harness.downLong()
        expectEqual(harness.keys, [])

        harness.finishVoiceCapture()
        harness.commitVoiceText("AB", caret: 2)
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
        harness.commitVoiceText("AB", caret: 2)
        expectEqual(harness.keys, [])

        harness.downClick()
        expectEqual(harness.keys, [.returnKey])
    }

    func testOkClickSendsOneBackspaceWhileIdle() {
        let harness = Harness()
        harness.connect()
        harness.control(["type": "button_event", "button": "ok", "event": "click"])
        expectEqual(harness.keys.map(\.keyCode), [51]) // macOS Delete (Backspace)
    }

    func testOkClickDoesNotRunDuringRecordingOrWaitForVoiceText() {
        let harness = Harness()
        harness.connect()
        let okClick = ["type": "button_event", "button": "ok", "event": "click"]
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.control(okClick)
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 0])
        harness.outputs[0].completeDrain()
        harness.control(okClick)
        harness.input.text = "A你好Z"
        harness.input.selection = NSRange(location: 3, length: 0)
        harness.bridge.tick(now: harness.now + .milliseconds(100))
        expectEqual(harness.keys, [])
    }

    func testReturnPressedJustAfterUpWaitsForTheDelayedPttUpAndVoiceText() {
        let harness = Harness()
        harness.connect()
        let pressedAfterUp: [String: Any] = [
            "type": "button_event", "button": "down", "event": "click", "sessionId": 1,
        ]
        harness.control(pressedAfterUp)
        expectEqual(harness.keys, [])
        harness.control(["type": "ptt_down", "sessionId": 1])
        harness.frame(session: 1, sequence: 0, sample: 12)
        harness.control(pressedAfterUp)
        harness.control(["type": "ptt_up", "sessionId": 1, "finalSequence": 0])
        harness.outputs[0].completeDrain()
        expectEqual(harness.keys, [])

        harness.input.text = "A你好Z"
        harness.input.selection = NSRange(location: 3, length: 0)
        harness.bridge.tick(now: harness.now + .milliseconds(100))
        expectEqual(harness.keys, [.returnKey])
    }

    func testTaggedReturnDoesNotFollowAnAbortedOrDifferentSession() {
        for abort in [false, true] {
            let harness = Harness()
            harness.connect()
            harness.control(["type": "button_event", "button": "down", "event": "click", "sessionId": 1])
            if abort { harness.control(["type": "device_error", "sessionId": 1]) }
            let session: UInt32 = abort ? 1 : 2
            harness.control(["type": "ptt_down", "sessionId": session])
            harness.frame(session: session, sequence: 0, sample: 12)
            harness.control(["type": "ptt_up", "sessionId": session, "finalSequence": 0])
            harness.outputs[0].completeDrain()
            harness.input.text = "A你好Z"
            harness.input.selection = NSRange(location: 3, length: 0)
            harness.bridge.tick(now: harness.now + .milliseconds(100))
            expectEqual(harness.keys, [])
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
tests.testDownDuringRecordingIsIgnoredAndQueuedReturnsWaitForVoiceText()
tests.testQueuedReturnIsDroppedIfInputChangesBeforeUpStopsRecording()
tests.testQueuedReturnIsDroppedAfterLosingAndRegainingFocus()
tests.testQueuedReturnIsDroppedWhenAnotherInputCouldHaveInsertedTheText()
tests.testQueuedReturnExpiresBeforeALateCommitAndNewPressWorks()
tests.testOKLongDeletesCommittedVoiceTextAndKeepsLaterTyping()
tests.testOKLongKeepsTypingInsertedBeforeTheCommittedRange()
tests.testOKLongSkipsWhenRepeatedTextMakesTheRangeAmbiguous()
tests.testOKLongSkipsWhenTheVoiceTextMayHaveAlreadyBeenRemoved()
tests.testOKLongSkipsTheNewlyFocusedInput()
tests.testOKLongSkipsWhenTheSelectionCannotBeRead()
tests.testOKLongDoesNotDeleteVoiceTextAgainAfterTheFirstDeletion()
tests.testOKLongDuringRecordingAndCommitWaitDoesNotQueueDeletion()
tests.testOKLongCanDeleteTheCommitAlsoUsedForQueuedReturn()
tests.testFinishWaitsForInclusiveTailAndBlackHoleDrainBeforeAllowingAnotherSession()
tests.testMissingTailFrameIsFilledWithSilenceAfterWaiting()
tests.testReconnectWaitsForDisconnectedCaptureToDrainAndCanReuseSessionID()
try tests.testHelperDeliversShortHandshakeBeforeWaitingForReply()
tests.testOkClickSendsOneBackspaceWhileIdle()
tests.testOkClickDoesNotRunDuringRecordingOrWaitForVoiceText()
tests.testReturnPressedJustAfterUpWaitsForTheDelayedPttUpAndVoiceText()
tests.testTaggedReturnDoesNotFollowAnAbortedOrDifferentSession()
tests.testChangingEachBindingTakesEffectOnTheCurrentBridge()
tests.testSavedShortcutSendsItsKeyAndModifiersAfterReloadingBindings()
tests.testRestoringDefaultsClearsAllSavedBindings()
tests.testDownLongDoesNotSendOrQueueItsBindingDuringCapture()
tests.testCustomReturnIsIgnoredWhileRecordingAndNeverDeferred()
print("28 Passport bridge tests passed")
