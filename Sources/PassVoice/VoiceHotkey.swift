import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct VoiceHotkey {
    static let eventTag: Int64 = 0x5061_7373_566F_6963

    static func checkAccess() throws {
        guard CGPreflightPostEventAccess() else {
            throw BridgeError("""
                Keystroke permission is unavailable. Allow your launcher in System Settings > Privacy & Security                 > Accessibility, then restart it. Use --manual to test audio with your physical shortcut.
                """)
        }
    }

    static func tapRightOption() throws {
        try checkAccess()
        let key = CGKeyCode(kVK_RightOption)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw BridgeError("Unable to create the right Option keystroke")
        }
        let rightOption = CGEventFlags(rawValue: 0x40) // NX_DEVICERALTKEYMASK
        let originalFlags = CGEventSource.flagsState(.combinedSessionState)
        guard !originalFlags.contains(rightOption) else {
            throw BridgeError("Release the physical right Option key before using the Passport shortcut")
        }
        down.type = .flagsChanged
        down.setIntegerValueField(.eventSourceUserData, value: eventTag)
        down.flags = originalFlags.union([.maskAlternate, rightOption])
        up.type = .flagsChanged
        up.setIntegerValueField(.eventSourceUserData, value: eventTag)
        up.flags = originalFlags
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.035)
        up.post(tap: .cghidEventTap)
    }
}
