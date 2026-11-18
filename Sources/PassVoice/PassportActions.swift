import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum PassportGesture: String {
    case downClick, downLong, okClick, okLong

    init?(button: String?, event: String?) {
        switch (button, event) {
        case ("down", "click"): self = .downClick
        case ("down", "long"): self = .downLong
        case ("ok", "click"): self = .okClick
        case ("ok", "long"): self = .okLong
        default: return nil
        }
    }
}

enum PassportAction: Equatable, Codable {
    case returnKey, backspace, undo, none
    // Retained for existing saved bindings.
    case deleteVoiceInput
    case shortcut(PassportKeystroke, keyName: String)

    static func defaultAction(for gesture: PassportGesture) -> Self {
        switch gesture {
        case .downClick: return .returnKey
        case .downLong: return .none
        case .okClick: return .backspace
        case .okLong: return .undo
        }
    }
}

struct PassportKeystroke: Hashable, Codable {
    struct Modifiers: OptionSet, Hashable, Codable {
        let rawValue: UInt64

        static let control = Self(rawValue: CGEventFlags.maskControl.rawValue)
        static let option = Self(rawValue: CGEventFlags.maskAlternate.rawValue)
        static let shift = Self(rawValue: CGEventFlags.maskShift.rawValue)
        static let command = Self(rawValue: CGEventFlags.maskCommand.rawValue)
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static let returnKey = Self(keyCode: UInt16(kVK_Return))
    static let backspace = Self(keyCode: UInt16(kVK_Delete))
    static let undo = Self(keyCode: UInt16(kVK_ANSI_Z), modifiers: .command)
}
