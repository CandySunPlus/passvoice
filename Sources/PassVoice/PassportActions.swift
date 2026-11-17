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
    case returnKey, backspace, deleteVoiceInput, none
    case shortcut(PassportKeystroke, keyName: String)

    static func defaultAction(for gesture: PassportGesture) -> Self {
        switch gesture {
        case .downClick: return .returnKey
        case .downLong: return .none
        case .okClick: return .backspace
        case .okLong: return .deleteVoiceInput
        }
    }
}

struct PassportKeystroke: Equatable, Codable {
    struct Modifiers: OptionSet, Codable {
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
}

struct PassportTextState: Equatable {
    let text: String
    let selectedRange: NSRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedRange == rhs.selectedRange && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }

    func indices(of range: NSRange) -> Range<String.Index>? {
        let count = text.utf16.count
        guard range.location >= 0, range.location <= count, range.length >= 0,
              range.length <= count - range.location else { return nil }
        return Range(range, in: text)
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

    func retainedRange(_ range: NSRange, in updated: Self) -> NSRange? {
        guard updated.indices(of: updated.selectedRange) != nil else { return nil }
        let before = text.utf16
        let after = updated.text.utf16
        let beforeLength = before.count
        let afterLength = after.count
        let sharedLength = min(beforeLength, afterLength)
        let prefix = zip(before, after).lazy
            .prefix { $0.0 == $0.1 }.reduce(0) { length, _ in length + 1 }
        if prefix == beforeLength, prefix == afterLength { return range }
        let suffix = zip(before.reversed(), after.reversed()).lazy
            .prefix { $0.0 == $0.1 }.reduce(0) { length, _ in length + 1 }

        // If the matches overlap, several edit positions can explain the change.
        // Only keep text that is outside the edit at every such position.
        let stablePrefix = min(prefix, sharedLength - suffix)
        let stableSuffix = min(suffix, sharedLength - prefix)
        let location: Int
        if NSMaxRange(range) <= stablePrefix {
            location = range.location
        } else if beforeLength - range.location <= stableSuffix {
            location = range.location + (afterLength - beforeLength)
        } else {
            return nil
        }
        let retained = NSRange(location: location, length: range.length)
        return updated.indices(of: retained) == nil ? nil : retained
    }
}

protocol PassportVoiceTarget: AnyObject {
    // False after another input or input source change during observation.
    var canConfirmVoiceText: Bool { get }

    // Nil after any loss of focus or if the input cannot be read.
    func snapshot() -> PassportTextState?

    // Recheck at delivery, so a deferred keystroke cannot follow the new focus.
    func send(_ key: PassportKeystroke, ifSnapshotIs expected: PassportTextState) throws

    // Stop observing competing input once the commit is known. Keep observing focus.
    func finishCommitObservation()

    func delete(_ range: NSRange, ifSnapshotIs expected: PassportTextState) throws
}
