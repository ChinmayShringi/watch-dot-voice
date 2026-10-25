/// Local presentation preferences, independent of the connected account and companion.
public enum CompanionAppearance: String, CaseIterable, Sendable, Identifiable {
    case sprite, pebble, orbit, pixel

    public var id: String { rawValue }

    public static func available(spriteAvailable: Bool) -> [Self] {
        allCases.filter { spriteAvailable || $0 != .sprite }
    }

    public static func resolve(savedID: String, spriteAvailable: Bool) -> Self {
        guard let appearance = Self(rawValue: savedID),
              appearance != .sprite || spriteAvailable else { return .pebble }
        return appearance
    }

    public func displayName(spriteName: String) -> String {
        switch self {
        case .sprite: spriteName
        case .pebble: "Pebble"
        case .orbit: "Orbit"
        case .pixel: "Pixel"
        }
    }
}
