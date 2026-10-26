import Foundation

public enum AvatarLayout {
    public static let listeningGrowth = 0.06
    public static let bobAmplitude = 2.0
    public static let safetyInset = 2.0

    /// Reserve the full motion envelope so changing voice state never resizes the character.
    public static func glyphSide(width: Double, height: Double, appearance: CompanionAppearance) -> Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
        let bounds: (width: Double, height: Double)
        switch appearance {
        case .sprite, .pebble:
            let angle = 7 * Double.pi / 180
            bounds = (0.88 * cos(angle) + 0.94 * sin(angle),
                      0.94 * cos(angle) + 0.88 * sin(angle))
        case .orbit:
            // The satellite's full orbit exceeds the stroked ring's diameter.
            bounds = (1.06, 1.06)
        case .pixel:
            bounds = (0.88, 0.88)
        }
        let scale = 1 + listeningGrowth
        let availableWidth = max(0, width - 2 * safetyInset)
        let availableHeight = max(0, height - 2 * (safetyInset + bobAmplitude))
        return min(availableWidth / (bounds.width * scale), availableHeight / (bounds.height * scale))
    }
}
