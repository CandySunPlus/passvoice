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
        down.flags = []
        up.flags = []
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

    private let element: AXUIElement
    private let processID: pid_t
    private var lostFocus = false
    private var otherInput = false
    private var focusObserver: AXObserver?
    private var inputTap: CFMachPort?
    private var inputRunLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?

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
        guard !lostFocus, !otherInput, let inputTap, CGEvent.tapIsEnabled(tap: inputTap),
              !IsSecureEventInputEnabled(), Self.doubaoIsSelected() else {
            otherInput = true
            return false
        }
        return true
    }

    func snapshot() -> PassportTextState? {
        guard stillFocused() else { return nil }
        var attributes: CFArray?
        let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, .stopOnError, &attributes) == .success,
              let values = attributes as? [AnyObject], values.count == 2,
              let text = values[0] as? String, CFGetTypeID(values[1]) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        let selectedRange = values[1] as! AXValue // Checked the CF type above.
        guard AXValueGetValue(selectedRange, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0, stillFocused() else { return nil }
        return PassportTextState(text: text, selectedRange: NSRange(location: selection.location, length: selection.length))
    }

    func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) throws {
        guard snapshot() == expected, canConfirmVoiceText else { return }
        try PassportMacInput.send(key, to: processID)
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
        guard AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            Unmanaged<MacVoiceTarget>.fromOpaque(context).takeUnretainedValue().lostFocus = true
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
            self.lostFocus = true
        }
        return true
    }

    private func observeInput() -> Bool {
        let mask = Self.inputEvents.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        // Read no key codes or characters. A competing input event only invalidates attribution.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, _, event, context in
                if let context, event.getIntegerValueField(.eventSourceUserData) != VoiceHotkey.eventTag {
                    Unmanaged<MacVoiceTarget>.fromOpaque(context).takeUnretainedValue().otherInput = true
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        inputTap = tap
        inputRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.inputSourceDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.otherInput = true }
        return true
    }

    deinit {
        let runLoop = CFRunLoopGetMain()
        if let focusObserver { CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(focusObserver), .commonModes) }
        if let inputRunLoopSource { CFRunLoopRemoveSource(runLoop, inputRunLoopSource, .commonModes) }
        if let inputTap { CFMachPortInvalidate(inputTap) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
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
