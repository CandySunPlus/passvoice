import Foundation

struct PassportButtonBindings {
    private let defaults: UserDefaults
    private let preferenceKey = "passportButtonBindings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func action(for gesture: PassportGesture) -> PassportAction {
        if let data = overrides[gesture.rawValue] as? Data,
           let action = try? PropertyListDecoder().decode(PassportAction.self, from: data) {
            return action
        }
        return PassportAction.defaultAction(for: gesture)
    }

    func set(_ action: PassportAction, for gesture: PassportGesture) {
        guard let encoded = try? PropertyListEncoder().encode(action) else { return }
        var updated = overrides
        updated[gesture.rawValue] = encoded
        defaults.set(updated, forKey: preferenceKey)
    }

    func restoreDefaults() {
        defaults.removeObject(forKey: preferenceKey)
    }

    private var overrides: [String: Any] { defaults.dictionary(forKey: preferenceKey) ?? [:] }
}
