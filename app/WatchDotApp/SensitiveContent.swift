import SwiftUI

private struct SensitiveContent: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons
    let placeholder: String?

    private var isVisible: Bool {
        SensitiveContentPolicy.isVisible(isActive: scenePhase == .active,
            luminanceReduced: luminanceReduced, privacyRedacted: redactionReasons.contains(.privacy))
    }

    func body(content: Content) -> some View {
        content
            .privacySensitive()
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .allowsHitTesting(isVisible)
            .overlay {
                if !isVisible, let placeholder {
                    Text(placeholder)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .unredacted()
                        .allowsHitTesting(false)
                }
            }
            .transaction { if !isVisible { $0.animation = nil } }
    }
}

extension View {
    func sensitiveContent(placeholder: String? = "Content hidden") -> some View {
        modifier(SensitiveContent(placeholder: placeholder))
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct LayoutPrivacyPreview: ViewModifier {
    enum Mode { case privacy, luminance }

    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @State private var isProtected = false
    let mode: Mode

    func body(content: Content) -> some View {
        content
            .environment(\.redactionReasons,
                redactionReasons.union(isProtected && mode == .privacy ? .privacy : []))
            .environment(\.isLuminanceReduced,
                luminanceReduced || (isProtected && mode == .luminance))
            .task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(12))
                        isProtected = true
                        try await Task.sleep(for: .seconds(6))
                        isProtected = false
                    }
                } catch {
                    isProtected = false
                }
            }
    }
}

extension View {
    @ViewBuilder func layoutPrivacyPreview(enabled: Bool) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        let privacy = arguments.contains("--preview-privacy")
        let luminance = arguments.contains("--preview-luminance")
        if enabled && privacy != luminance {
            modifier(LayoutPrivacyPreview(mode: privacy ? .privacy : .luminance))
        } else {
            self
        }
    }
}
#endif
