/// Separates downloaded avatar identifiers from the existing local appearance preference.
public enum AvatarSelection {
    private static let prefix = "pet:"

    public static func identifier(for petID: String) -> String { prefix + petID }

    public static func petID(from selection: String) -> String? {
        guard selection.hasPrefix(prefix) else { return nil }
        let value = String(selection.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    public static func page(current: String, selected: String, available: [String]) -> String {
        if available.contains(current) { return current }
        if available.contains(selected) { return selected }
        return available.first ?? CompanionAppearance.pebble.rawValue
    }
}
