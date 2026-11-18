import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PassportMacInput {
    static func observeVoiceTarget() -> PassportVoiceTarget? {
        MacVoiceTarget.observe()
    }

    static func send(_ key: PassportKeystroke, to processID: pid_t? = nil) throws {
        try VoiceHotkey.checkAccess()
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: false) else {
            throw BridgeError("Unable to create the Passport keystroke")
        }
        let flags = CGEventFlags(rawValue: key.modifiers.rawValue)
        down.flags = flags
        up.flags = flags
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
    private var lostFocus = false
    private var otherInput = false
    private var focusObserver: AXObserver?
    private var inputTap: CFMachPort?
    private var inputRunLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var onEdit: ((PassportEditObservation) -> Void)?

    private init(element: AXUIElement, processID: pid_t) {
        self.element = element
        self.processID = processID
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
        let target = MacVoiceTarget(element: element, processID: pid)
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
              let text = values[0] as? String,
              let selection = Self.textRange(from: values[1]) else { return nil }
        let composition = compositionState()
        guard stillFocused() else { return nil }
        return PassportTextState(text: text, selectedRange: selection, composition: composition)
    }

    func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) throws {
        guard snapshot() == expected, canConfirmVoiceText else { return }
        try PassportMacInput.send(key, to: processID)
    }

    func delete(_ range: NSRange, ifSnapshotIs expected: PassportTextState) throws {
        let selectionAttribute = kAXSelectedTextRangeAttribute as CFString
        let textAttribute = kAXSelectedTextAttribute as CFString
        guard range.length > 0, let indices = expected.indices(of: range),
              let originalSelection = Self.rangeValue(expected.selectedRange),
              let voiceSelection = Self.rangeValue(range),
              onEdit != nil, canListenToInput, stillFocused(),
              isSettable(selectionAttribute), isSettable(textAttribute),
              hasOnlySelection(expected.selectedRange), snapshot() == expected,
              !IsSecureEventInputEnabled() else { return }

        let selected = PassportTextState(text: expected.text, selectedRange: range, composition: expected.composition)
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

        let remaining = expected.text.replacingCharacters(in: indices, with: "")
        guard AXUIElementSetAttributeValue(element, textAttribute, "" as CFString) == .success,
              let updated = snapshot(), updated.text.utf16.elementsEqual(remaining.utf16) else {
            throw BridgeError("The input could not confirm deletion of the selected text")
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
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func hasOnlySelection(_ selection: NSRange) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangesAttribute as CFString, &value)
        if result == .attributeUnsupported { return true }
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
            self?.otherInput = true
            self?.onEdit?(.uncertain)
        }
        return true
    }

    private func inputChanged(_ type: CGEventType, event: CGEvent) {
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
        guard let element = attribute(kAXFocusedUIElementAttribute, of: systemAccessibility),
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement) // Checked the CF type above.
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
