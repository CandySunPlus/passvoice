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

struct PassportTextState: Equatable {
    let text: String
    let selectedRange: NSRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedRange == rhs.selectedRange && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }

    // AX selections use UTF-16 offsets. The only accepted edit replaces the
    // original selection and leaves the caret immediately after the new text.
    func insertedRange(in updated: Self) -> NSRange? {
        let start = selectedRange.location
        let end = updated.selectedRange.location
        let oldText = Array(text.utf16)
        let newText = Array(updated.text.utf16)
        guard start >= 0, start <= oldText.count, selectedRange.length >= 0,
              selectedRange.length <= oldText.count - start,
              updated.selectedRange.length == 0, end > start, end <= newText.count,
              oldText != newText else { return nil }
        let oldEnd = start + selectedRange.length
        guard oldText[..<start].elementsEqual(newText[..<start]),
              oldText[oldEnd...].elementsEqual(newText[end...]) else { return nil }
        let inserted = NSRange(location: start, length: end - start)
        guard Range(selectedRange, in: text) != nil, Range(inserted, in: updated.text) != nil else { return nil }
        return inserted
    }
}

protocol PassportVoiceTarget: AnyObject {
    // False after another input or input source change during observation.
    var canConfirmVoiceText: Bool { get }

    // Nil after any loss of focus or if the input cannot be read.
    func snapshot() -> PassportTextState?

    // Recheck at delivery, so a deferred keystroke cannot follow the new focus.
    func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) throws
}
