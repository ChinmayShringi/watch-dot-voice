/// Content stays private until both the app and its display are ready for the wearer.
public enum SensitiveContentPolicy {
    public static func isVisible(isActive: Bool, luminanceReduced: Bool,
                                 privacyRedacted: Bool) -> Bool {
        isActive && !luminanceReduced && !privacyRedacted
    }
}
