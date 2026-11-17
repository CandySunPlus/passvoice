import Carbon.HIToolbox
import Foundation

enum PassportGesture: Hashable {
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

enum PassportAction: Equatable {
    case returnKey, none

    static func defaultAction(for gesture: PassportGesture) -> Self {
        gesture == .downClick ? .returnKey : .none
    }
}

struct PassportKeystroke: Equatable {
    let keyCode: UInt16

    static let returnKey = Self(keyCode: UInt16(kVK_Return))
}
