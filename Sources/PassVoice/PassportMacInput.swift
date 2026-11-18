import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PassportMacInput {
    static func observeVoiceTarget() -> PassportVoiceTarget? {
        MacVoiceTarget.observe()
    }

    static func send(_ key: PassportKeystroke, to processID: pid_t? = nil, tag: Int64 = 0) throws {
        try VoiceHotkey.checkAccess()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: false) else {
            throw BridgeError("Unable to create the Passport keystroke")
        }
        let flags = CGEventFlags(rawValue: key.modifiers.rawValue)
        down.flags = flags
        up.flags = flags
        if tag != 0 {
            down.setIntegerValueField(.eventSourceUserData, value: tag)
            up.setIntegerValueField(.eventSourceUserData, value: tag)
        }
        if let processID {
            down.postToPid(processID)
            up.postToPid(processID)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

// All observations and calls run on the main run loop, alongside the bridge.
private final class MacVoiceTarget: PassportVoiceTarget {
    private enum CodexEditorContent {
        case empty, readOnlyWidget(String)
    }

    private static let systemAccessibility: AXUIElement = {
        let system = AXUIElementCreateSystemWide()
        // This timeout applies to AX messages from PassVoice, including focus queries.
        _ = AXUIElementSetMessagingTimeout(system, 0.15)
        return system
    }()
    private static let doubaoBundleID = "com.bytedance.inputmethod.doubaoime"
    private static let inputSourceDidChange = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    private static let inputEvents: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]
    private static let typingKeys: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
        kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
        kVK_ANSI_Quote, kVK_ANSI_Semicolon, kVK_ANSI_Backslash, kVK_ANSI_Comma,
        kVK_ANSI_Slash, kVK_ANSI_Period, kVK_ANSI_Grave, kVK_Space,
    ]

    private let element: AXUIElement
    private let processID: pid_t
    private let isCodexEditor: Bool
    let canDeleteAttributedVoiceText: Bool
    private var lostFocus = false
    private var otherInput = false
    private var inputRevision: UInt64 = 0
    private var focusObserver: AXObserver?
    private var inputTap: CFMachPort?
    private var inputRunLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var onEdit: ((PassportEditObservation) -> Void)?

    private init(element: AXUIElement, processID: pid_t, isCodexEditor: Bool, isTextEdit: Bool) {
        self.element = element
        self.processID = processID
        self.isCodexEditor = isCodexEditor
        canDeleteAttributedVoiceText = isCodexEditor || isTextEdit
    }

    static func observe() -> MacVoiceTarget? {
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess(), !IsSecureEventInputEnabled(),
              doubaoIsSelected(), let element = focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let role = attribute(kAXRoleAttribute, of: element) as? String
        let subrole = attribute(kAXSubroleAttribute, of: element) as? String
        guard role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole,
              subrole != kAXSecureTextFieldSubrole else { return nil }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let isCodexEditor = role == kAXTextAreaRole && bundle == "com.openai.codex"
            && attribute("AXSelectedTextMarkerRange", of: element) != nil
        let isTextEdit = role == kAXTextAreaRole && bundle == "com.apple.TextEdit"
            && attributeIsSettable(kAXSelectedTextRangeAttribute as CFString, of: element) == true
            && attributeIsSettable(kAXSelectedTextAttribute as CFString, of: element) == true
        let target = MacVoiceTarget(element: element, processID: pid, isCodexEditor: isCodexEditor, isTextEdit: isTextEdit)
        guard target.observeFocus() && target.observeInput() else { return nil }
        return target
    }

    var canConfirmVoiceText: Bool {
        guard !lostFocus, !otherInput, canListenToInput, Self.doubaoIsSelected() else {
            otherInput = true
            return false
        }
        return true
    }

    var isFocused: Bool { stillFocused() }

    private var canListenToInput: Bool {
        guard let inputTap else { return false }
        return CGEvent.tapIsEnabled(tap: inputTap) && !IsSecureEventInputEnabled()
    }

    func snapshot() -> PassportTextState? {
        guard stillFocused() else { return nil }
        var attributes: CFArray?
        let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, .stopOnError, &attributes) == .success,
              let values = attributes as? [AnyObject], values.count == 2,
              let value = values[0] as? String,
              let selection = Self.textRange(from: values[1]) else { return nil }
        let composition = compositionState()
        let content = isCodexEditor && composition != .composing ? codexEditorContent(value, at: selection) : nil
        guard stillFocused() else { return nil }
        switch content {
        case .empty:
            return PassportTextState(text: "", selectedRange: selection, composition: composition)
        case let .readOnlyWidget(label):
            return PassportTextState(text: value, selectedRange: selection, composition: composition, readOnlyWidget: label)
        case nil:
            return PassportTextState(text: value, selectedRange: selection, composition: composition)
        }
    }

    private func codexEditorContent(_ value: String, at selection: NSRange) -> CodexEditorContent? {
        guard selection == NSRange(location: 0, length: 0), !value.isEmpty else { return nil }
        let isEmptyLine = value == "\n"
        let prompt = value.last == "\n" ? String(value.dropLast()) : value
        guard isEmptyLine || (!prompt.isEmpty && !prompt.contains(where: \.isNewline)) else { return nil }

        // Chromium can include a read-only widget's text in the editable value.
        // Recognize the widget only when it accounts for the entire value.
        let selectionAttribute = kAXSelectedTextRangeAttribute as CFString
        var container = element
        for _ in 0..<3 {
            guard let children = Self.attribute(kAXChildrenAttribute, of: container) as? [AXUIElement],
                  children.count == 1,
                  let child = children.first,
                  Self.attribute(kAXRoleAttribute, of: child) as? String == kAXGroupRole else { return nil }
            if isEmptyLine {
                // An empty Chromium editor can expose only its caret line.
                // Typing Enter or Shift-Enter adds another line break to AXValue.
                return (Self.attribute(kAXChildrenAttribute, of: child) as? [AXUIElement])?.isEmpty == true ? .empty : nil
            }
            if Self.attributeIsSettable(selectionAttribute, of: child) == false {
                guard let contents = Self.attribute(kAXChildrenAttribute, of: child) as? [AXUIElement],
                      contents.count == 1, let text = contents.first,
                      Self.attribute(kAXRoleAttribute, of: text) as? String == kAXStaticTextRole,
                      Self.attributeIsSettable(selectionAttribute, of: text) == false,
                      let title = Self.attribute(kAXValueAttribute, of: text) as? String,
                      title.utf16.elementsEqual(prompt.utf16) else { return nil }
                return .readOnlyWidget(prompt)
            }
            container = child
        }
        return nil
    }

    func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) throws {
        guard snapshot() == expected, canConfirmVoiceText else { return }
        try PassportMacInput.send(key, to: processID)
    }

    func delete(_ range: NSRange, ifSnapshotIs expected: PassportTextState, onDeletion: @escaping () -> Void) throws {
        let selectionAttribute = kAXSelectedTextRangeAttribute as CFString
        let textAttribute = kAXSelectedTextAttribute as CFString
        guard range.length > 0, let indices = expected.indices(of: range),
              let originalSelection = Self.rangeValue(expected.selectedRange),
              let voiceSelection = Self.rangeValue(range),
              onEdit != nil, canListenToInput, stillFocused(), isSettable(selectionAttribute),
              hasOnlySelection(expected.selectedRange), snapshot() == expected,
              !IsSecureEventInputEnabled() else { return }

        let selected = PassportTextState(text: expected.text, selectedRange: range, composition: expected.composition)
        let remaining = expected.text.replacingCharacters(in: indices, with: "")
        if isCodexEditor {
            guard expected.composition != .composing else { return }
            let revision = inputRevision
            guard AXUIElementSetAttributeValue(element, selectionAttribute, voiceSelection) == .success else { return }
            deleteCodexSelection(expected: expected, selected: selected, remaining: remaining,
                                 revision: revision, attempts: 9, onDeletion: onDeletion)
            return
        }
        guard isSettable(textAttribute) else { return }
        let changesSelection = range != expected.selectedRange
        defer {
            // Restore the selection if the text did not change and we still own this selection.
            if changesSelection, hasOnlySelection(range), snapshot() == selected, !IsSecureEventInputEnabled() {
                _ = AXUIElementSetAttributeValue(element, selectionAttribute, originalSelection)
            }
        }
        if changesSelection {
            guard AXUIElementSetAttributeValue(element, selectionAttribute, voiceSelection) == .success else { return }
        }
        guard let selectedText = Self.attribute(kAXSelectedTextAttribute, of: element) as? String,
              selectedText.utf16.elementsEqual(expected.text[indices].utf16),
              hasOnlySelection(range), snapshot() == selected, !IsSecureEventInputEnabled() else { return }

        guard AXUIElementSetAttributeValue(element, textAttribute, "" as CFString) == .success,
              let updated = snapshot(), updated.text.utf16.elementsEqual(remaining.utf16) else {
            throw BridgeError("The input could not confirm deletion of the selected text")
        }
        onDeletion()
    }

    private func deleteCodexSelection(expected: PassportTextState, selected: PassportTextState,
                                      remaining: String, revision: UInt64, attempts: Int,
                                      onDeletion: @escaping () -> Void) {
        guard inputRevision == revision, canListenToInput, let current = snapshot(),
              current == expected || current == selected else { return }
        // Chromium delivers the AX selection to its renderer asynchronously.
        // Send Backspace only after that renderer reports the exact voice span.
        if current == selected, hasOnlySelection(selected.selectedRange),
           let range = selected.indices(of: selected.selectedRange),
           let text = Self.attribute(kAXSelectedTextAttribute, of: element) as? String,
           text.utf16.elementsEqual(selected.text[range].utf16),
           inputRevision == revision, canListenToInput, snapshot() == selected,
           (try? PassportMacInput.send(.backspace, to: processID, tag: VoiceHotkey.eventTag)) != nil {
            confirmCodexDeletion(before: selected, remaining: remaining, revision: revision,
                                 attempts: 9, onDeletion: onDeletion)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                self.deleteCodexSelection(expected: expected, selected: selected, remaining: remaining,
                                          revision: revision, attempts: attempts - 1, onDeletion: onDeletion)
            }
        } else if inputRevision == revision, canListenToInput, snapshot() == selected,
                  let original = Self.rangeValue(expected.selectedRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, original)
        }
    }

    private func confirmCodexDeletion(before: PassportTextState, remaining: String, revision: UInt64,
                                      attempts: Int, onDeletion: @escaping () -> Void) {
        guard inputRevision == revision, let current = snapshot() else { return }
        if current.text.utf16.elementsEqual(remaining.utf16) || (remaining.isEmpty && current.readOnlyWidget != nil) {
            onDeletion()
        } else if current.hasSameText(as: before), attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                self.confirmCodexDeletion(before: before, remaining: remaining, revision: revision,
                                          attempts: attempts - 1, onDeletion: onDeletion)
            }
        }
    }

    func stopMonitoringInput() {
        if let inputRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), inputRunLoopSource, .commonModes) }
        if let inputTap { CFMachPortInvalidate(inputTap) }
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
        inputRunLoopSource = nil
        inputTap = nil
        inputSourceObserver = nil
    }

    func monitorEdits(
        ifSnapshotIs expected: PassportTextState, onEdit: @escaping (PassportEditObservation) -> Void
    ) -> Bool {
        guard let focusObserver, canConfirmVoiceText, snapshot() == expected else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let value = kAXValueChangedNotification as CFString
        let selection = kAXSelectedTextChangedNotification as CFString
        guard AXObserverAddNotification(focusObserver, element, value, context) == .success else { return false }
        guard AXObserverAddNotification(focusObserver, element, selection, context) == .success else {
            _ = AXObserverRemoveNotification(focusObserver, element, value)
            return false
        }
        guard canConfirmVoiceText, snapshot() == expected else { return false }
        self.onEdit = onEdit
        return true
    }

    private func loseFocus() {
        lostFocus = true
        stopMonitoringInput()
        onEdit?(.uncertain)
    }

    private func accessibilityChanged(_ notification: String) {
        switch notification {
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
            guard let onEdit else { return }
            guard let current = snapshot() else {
                onEdit(.uncertain)
                return
            }
            onEdit(notification == kAXValueChangedNotification ? .value(current) : .selection(current))
        default:
            loseFocus()
        }
    }

    private func compositionState() -> PassportTextComposition {
        // Public AppKit NSAccessibilityTextInputMarkedRangeAttribute (macOS 10.6+).
        // Unsupported attributes and read failures do not prove that composition ended.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXTextInputMarkedRange" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return .unknown }
        var range = CFRange()
        let axValue = value as! AXValue // Checked the CF type above.
        guard AXValueGetValue(axValue, .cfRange, &range), range.length >= 0,
              range.location >= 0 || (range.location == kCFNotFound && range.length == 0) else { return .unknown }
        return range.length == 0 ? .clear : .composing
    }

    private func isSettable(_ attribute: CFString) -> Bool {
        Self.attributeIsSettable(attribute, of: element) == true
    }

    private static func attributeIsSettable(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success else { return nil }
        return settable.boolValue
    }

    private func hasOnlySelection(_ selection: NSRange) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangesAttribute as CFString, &value)
        if result == .attributeUnsupported { return true }
        if isCodexEditor, result == .failure || result == .noValue,
           let single = Self.attribute(kAXSelectedTextRangeAttribute, of: element), Self.textRange(from: single) == selection,
           let marker = Self.attribute("AXSelectedTextMarkerRange", of: element) {
            var length: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, "AXLengthForTextMarkerRange" as CFString,
                                                              marker, &length) == .success
                && (length as? NSNumber)?.intValue == selection.length
        }
        guard result == .success, let ranges = value as? [AnyObject], ranges.count == 1 else { return false }
        return Self.textRange(from: ranges[0]) == selection
    }

    private func stillFocused() -> Bool {
        guard !lostFocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let focused = Self.focusedElement(), CFEqual(focused, element) else {
            lostFocus = true
            return false
        }
        return true
    }

    private func observeFocus() -> Bool {
        var observer: AXObserver?
        guard AXObserverCreate(processID, { _, _, notification, context in
            guard let context else { return }
            Unmanaged<MacVoiceTarget>.fromOpaque(context).takeUnretainedValue()
                .accessibilityChanged(notification as String)
        }, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(processID)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context) == .success else {
            return false
        }
        _ = AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context)
        focusObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.processID else { return }
            self.loseFocus()
        }
        return true
    }

    private func observeInput() -> Bool {
        let mask = Self.inputEvents.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // During voice input, competing events only invalidate attribution. After
        // commit, distinguish delete keys without reading typed characters.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context, event.getIntegerValueField(.eventSourceUserData) != VoiceHotkey.eventTag {
                    Unmanaged<MacVoiceTarget>.fromOpaque(context).takeUnretainedValue().inputChanged(type, event: event)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        inputTap = tap
        inputRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.inputSourceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.inputRevision &+= 1
            self?.otherInput = true
            self?.onEdit?(.uncertain)
        }
        return true
    }

    private func inputChanged(_ type: CGEventType, event: CGEvent) {
        inputRevision &+= 1
        otherInput = true
        guard let onEdit else { return }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            onEdit(.uncertain)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onEdit(.input)
        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                onEdit(.uncertain)
            } else if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
                onEdit(.deletion(backward: keyCode == kVK_Delete))
            } else if canDeleteAttributedVoiceText, !event.flags.contains(.maskShift),
                      [kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter].contains(keyCode) {
                onEdit(.typingConfirmationKey(insertsText: keyCode == kVK_Space))
            } else if Self.typingKeys.contains(keyCode) {
                onEdit(.typing)
            } else if ![kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(keyCode) {
                onEdit(.input)
            }
        default:
            break
        }
    }

    deinit {
        stopMonitoringInput()
        let runLoop = CFRunLoopGetMain()
        if let focusObserver { CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    private static func textRange(from value: CFTypeRef) -> NSRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        let axValue = value as! AXValue // Checked the CF type above.
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func rangeValue(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }

    private static func doubaoIsSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let bundle = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        return (Unmanaged<CFString>.fromOpaque(bundle).takeUnretainedValue() as String) == doubaoBundleID
    }

    private static func focusedElement() -> AXUIElement? {
        if let element = attribute(kAXFocusedUIElementAttribute, of: systemAccessibility),
           CFGetTypeID(element) == AXUIElementGetTypeID() {
            return (element as! AXUIElement) // Checked the CF type above.
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.bundleIdentifier == "com.openai.codex",
              let element = attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(frontmost.processIdentifier)),
              CFGetTypeID(element) == AXUIElementGetTypeID(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier else { return nil }
        return (element as! AXUIElement) // Checked the CF type above.
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
