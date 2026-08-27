import Foundation

final class NameStore {
    private let key = "spaceNames.v1"
    private let defaults: UserDefaults
    private var names: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.names = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func name(for uuid: String) -> String? {
        let trimmed = names[uuid]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func setName(_ name: String, for uuid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: uuid)
        } else {
            names[uuid] = trimmed
        }
        defaults.set(names, forKey: key)
    }
}
