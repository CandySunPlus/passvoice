import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PassportMacInput {
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

final class MacInputTarget: PassportInputTarget {
    private static let systemAccessibility: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }()
    private static let enhancedAccessibility = "AXEnhancedUserInterface"
    private let application: NSRunningApplication
    private let appElement: AXUIElement
    private let element: AXUIElement

    private init(application: NSRunningApplication, appElement: AXUIElement, element: AXUIElement) {
        self.application = application
        self.appElement = appElement
        self.element = element
    }

    static func prepareFocus(for application: NSRunningApplication?) {
        guard let application, let appElement = accessibilityApplication(for: application),
              focusedElement(in: appElement, pid: application.processIdentifier) == nil else { return }
        requestEnhancedAccessibility(in: appElement)
    }

    static func observe() -> MacInputTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let appElement = accessibilityApplication(for: app) else { return nil }
        guard let element = focusedElement(in: appElement, pid: app.processIdentifier) else {
            requestEnhancedAccessibility(in: appElement)
            return nil
        }
        guard attribute(kAXSubroleAttribute, of: element) as? String != kAXSecureTextFieldSubrole,
              app.isActive else { return nil }
        return MacInputTarget(application: app, appElement: appElement, element: element)
    }

    var isFocused: Bool {
        guard application.isActive, !IsSecureEventInputEnabled(),
              let current = Self.focusedElement(in: appElement, pid: application.processIdentifier) else { return false }
        return CFEqual(current, element) && application.isActive
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    func send(_ key: PassportKeystroke) throws {
        guard isFocused else { throw BridgeError("The original Passport input lost focus") }
        try PassportMacInput.send(key, to: application.processIdentifier)
    }

    private static func accessibilityApplication(for application: NSRunningApplication) -> AXUIElement? {
        let pid = application.processIdentifier
        guard application.isActive, pid != ProcessInfo.processInfo.processIdentifier,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private static func requestEnhancedAccessibility(in app: AXUIElement) {
        var writable = DarwinBoolean(false)
        guard attribute(kAXFocusedWindowAttribute, of: app) != nil,
              attribute(enhancedAccessibility, of: app) as? Bool == false,
              AXUIElementIsAttributeSettable(app, enhancedAccessibility as CFString, &writable) == .success,
              writable.boolValue else { return }
        // The focused control can appear asynchronously, even if the setter reports an error.
        _ = AXUIElementSetAttributeValue(app, enhancedAccessibility as CFString, kCFBooleanTrue)
    }

    private static func focusedElement(in app: AXUIElement, pid: pid_t) -> AXUIElement? {
        for scope in [app, systemAccessibility] {
            guard let value = attribute(kAXFocusedUIElementAttribute, of: scope),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let element = value as! AXUIElement  // Checked the CF type above.
            var owner: pid_t = 0
            if AXUIElementGetPid(element, &owner) == .success, owner == pid { return element }
        }
        return nil
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

// Keep a single clipboard lease so a second paste can share the saved clipboard.
enum PassportDraftPaste {
    private static let paste = PassportKeystroke(keyCode: UInt16(kVK_ANSI_V), modifiers: .command)
    private static var savedItems: [NSPasteboardItem] = []
    private static var pasteChangeCount: Int?

    static func insert(_ text: String, into target: MacInputTarget) throws {
        guard target.isFocused else { throw BridgeError("The original Passport input lost focus") }
        let board = NSPasteboard.general
        if board.changeCount != pasteChangeCount {
            savedItems = (board.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }.filter { !$0.types.isEmpty }
        }
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            restore(to: board)
            throw BridgeError("Unable to prepare the Passport draft for paste")
        }
        let changeCount = board.changeCount
        pasteChangeCount = changeCount
        do {
            try target.send(paste)
        } catch {
            restore(to: board)
            throw error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
            guard pasteChangeCount == changeCount else { return }
            if board.changeCount == changeCount { restore(to: board) }
            else {
                pasteChangeCount = nil
                savedItems = []
            }
        }
    }

    private static func restore(to board: NSPasteboard) {
        board.clearContents()
        if !savedItems.isEmpty { board.writeObjects(savedItems) }
        pasteChangeCount = nil
        savedItems = []
    }
}
