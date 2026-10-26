import SwiftUI

struct SpriteAvatar: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons
    @ObservedObject private var store = SpriteFrameStore.shared
    let animation: AvatarAnimation
    var atlasURL: URL? = nil
    var playbackActive = true
    @State private var started = Date()
    @State private var frames: SpriteFrames?
    @State private var loadedGeneration: UUID?
    @State private var requestedGeneration: UUID?
    @State private var requestedURL: URL?
    @State private var loadingFailed = false

    private struct LoadID: Hashable {
        let url: URL?
        let playbackActive: Bool
        let focused: Bool
        let contentVisible: Bool
        let generation: UUID
    }

    private var animates: Bool {
        playbackActive && scenePhase == .active && !reduceMotion && !luminanceReduced &&
            !redactionReasons.contains(.privacy)
    }

    private var contentVisible: Bool {
        atlasURL == nil || SensitiveContentPolicy.isVisible(isActive: scenePhase == .active,
            luminanceReduced: luminanceReduced, privacyRedacted: redactionReasons.contains(.privacy))
    }

    var body: some View {
        GeometryReader { geometry in
            if contentVisible, let frames, loadedGeneration == store.generation {
                TimelineView(.animation(minimumInterval: 0.05, paused: !animates)) { context in
                    let state = animates ? animation : .idle
                    let frame = animates ? state.frame(at: context.date.timeIntervalSince(started)) : 0
                    Image(decorative: frames.image(animation: state, frame: frame), scale: 1)
                        .resizable().interpolation(.none).scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            } else {
                Image(systemName: contentVisible && loadingFailed ?
                    "person.crop.circle.badge.exclamationmark" : "person.crop.circle.fill")
                    .font(.largeTitle).foregroundStyle(.secondary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task(id: LoadID(url: atlasURL, playbackActive: animates, focused: playbackActive,
                         contentVisible: contentVisible,
                         generation: store.generation)) {
            frames = frames?.posterOnly
            loadingFailed = false
            guard contentVisible else { frames = nil; return }
            let generation = store.generation
            if atlasURL != nil, let requestedGeneration, requestedGeneration != generation, requestedURL == atlasURL {
                frames = nil
                return
            }
            requestedGeneration = generation
            requestedURL = atlasURL
            guard playbackActive else {
                frames = store.cachedPoster(atlasURL: atlasURL)
                loadedGeneration = generation
                return
            }
            do {
                let loaded = try await store.load(atlasURL: atlasURL, playbackActive: animates)
                try Task.checkCancellation()
                guard generation == store.generation else { return }
                frames = loaded
                loadedGeneration = generation
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, generation == store.generation else { return }
                frames = nil
                loadingFailed = true
            }
        }
        .onChange(of: animation) { _, _ in started = Date() }
        .onChange(of: animates) { _, active in
            started = Date()
            if !active { frames = frames?.posterOnly }
        }
        .onChange(of: atlasURL) { _, _ in frames = nil }
        .onChange(of: contentVisible) { _, visible in if !visible { frames = nil } }
        .onChange(of: store.generation) { _, _ in frames = nil }
        .onDisappear { frames = nil }
        .accessibilityHidden(true)
    }
}
