import SwiftUI
import WatchKit

struct CompanionAvatar: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    let appearance: CompanionAppearance
    let animation: AvatarAnimation
    let level: Double
    var atlasURL: URL? = nil
    var playbackActive = true

    static let spriteAvailable = UIImage(named: "AvatarAtlas") != nil

    var body: some View {
        Group {
            if atlasURL != nil || (appearance == .sprite && Self.spriteAvailable) {
                SpriteAvatar(animation: animation, atlasURL: atlasURL, playbackActive: playbackActive)
            } else {
                OriginalCompanionAvatar(appearance: appearance, animation: animation, level: level,
                    playbackActive: playbackActive)
            }
        }
        .background {
            if animation == .listening && scenePhase == .active && !luminanceReduced {
                microphoneLevel
            }
        }
        .accessibilityHidden(true)
    }

    private var microphoneLevel: some View {
        let meter = level.isFinite ? min(1, max(0, level)) : 0
        return GeometryReader { geometry in
            let diameter = max(0, min(geometry.size.width, geometry.size.height) - 6)
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : meter)
                    .stroke(.mint.opacity(reduceMotion ? 0.25 + meter * 0.75 : 1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .animation(nil, value: meter)
        }
        .allowsHitTesting(false)
    }
}

private struct OriginalCompanionAvatar: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    let appearance: CompanionAppearance
    let animation: AvatarAnimation
    let level: Double
    let playbackActive: Bool
    @State private var started = Date()

    private var animates: Bool { playbackActive && scenePhase == .active && !reduceMotion && !luminanceReduced }
    private var tint: Color {
        switch appearance {
        case .sprite, .pebble: Color(red: 0.73, green: 0.65, blue: 1)
        case .orbit: Color(red: 0.40, green: 0.89, blue: 0.81)
        case .pixel: Color(red: 1, green: 0.74, blue: 0.35)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = AvatarLayout.glyphSide(width: geometry.size.width, height: geometry.size.height,
                appearance: appearance)
            TimelineView(.animation(minimumInterval: 0.05, paused: !animates)) { context in
                let elapsed = animates ? context.date.timeIntervalSince(started) : 0
                let state = AvatarAnimation.displayed(animation, active: scenePhase == .active,
                    reduceMotion: reduceMotion, luminanceReduced: luminanceReduced)
                let meter = state == .listening && level.isFinite ? min(1, max(0, level)) : 0
                character(side: side, state: state, elapsed: elapsed)
                    .scaleEffect(1 + meter * AvatarLayout.listeningGrowth)
                    .offset(y: animates ? sin(elapsed * 1.8) * AvatarLayout.bobAmplitude : 0)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .onChange(of: animation) { _, _ in started = Date() }
        .onChange(of: animates) { _, _ in started = Date() }
    }

    private func character(side: CGFloat, state: AvatarAnimation, elapsed: Double) -> some View {
        ZStack {
            bodyShape(side: side, elapsed: elapsed)
            face(side: side, state: state, elapsed: elapsed)
        }
        .frame(width: side, height: side)
    }

    @ViewBuilder
    private func bodyShape(side: CGFloat, elapsed: Double) -> some View {
        switch appearance {
        case .sprite, .pebble:
            RoundedRectangle(cornerRadius: side * 0.40, style: .continuous)
                .fill(tint.gradient)
                .frame(width: side * 0.88, height: side * 0.94)
                .rotationEffect(.degrees(-7))
                .overlay(alignment: .topLeading) {
                    Capsule().fill(.white.opacity(0.30))
                        .frame(width: side * 0.20, height: side * 0.035)
                        .rotationEffect(.degrees(-35))
                        .offset(x: side * 0.12, y: side * 0.12)
                }
        case .orbit:
            Circle().stroke(tint.opacity(0.50), lineWidth: side * 0.025)
                .frame(width: side * 0.97, height: side * 0.97)
            Circle().fill(tint.gradient)
                .frame(width: side * 0.72, height: side * 0.72)
            Circle().fill(.white)
                .frame(width: side * 0.10, height: side * 0.10)
                .offset(x: side * 0.48)
                .rotationEffect(.degrees(-50 + sin(elapsed) * 12))
        case .pixel:
            PixelSilhouette().fill(tint.gradient)
                .frame(width: side * 0.88, height: side * 0.88)
            Rectangle().fill(.white.opacity(0.30))
                .frame(width: side * 0.13, height: side * 0.045)
                .offset(x: -side * 0.24, y: -side * 0.27)
        }
    }

    private func face(side: CGFloat, state: AvatarAnimation, elapsed: Double) -> some View {
        let blink = animates && elapsed.truncatingRemainder(dividingBy: 4.8) > 4.6
        let eyeHeight = side * (blink ? 0.025 : 0.115)
        let glance = state == .working ? sin(elapsed * 2) * side * 0.025 : 0
        return VStack(spacing: side * 0.10) {
            HStack(spacing: side * 0.16) {
                eye(side: side, height: eyeHeight)
                eye(side: side, height: eyeHeight)
            }
            .offset(x: glance)
            Capsule()
                .fill(.black.opacity(0.82))
                .frame(width: side * (state == .replied ? 0.18 : 0.09), height: side * 0.035)
                .rotationEffect(.degrees(state == .failed ? -14 : 0))
        }
        .offset(y: side * 0.025)
    }

    private func eye(side: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: appearance == .pixel ? 1 : side * 0.04)
            .fill(.black.opacity(0.88))
            .frame(width: side * 0.065, height: height)
    }
}

private struct PixelSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.14
        return Path { path in
            path.move(to: CGPoint(x: inset, y: 0))
            path.addLines([
                CGPoint(x: rect.width - inset, y: 0),
                CGPoint(x: rect.width - inset, y: inset),
                CGPoint(x: rect.width, y: inset),
                CGPoint(x: rect.width, y: rect.height - inset),
                CGPoint(x: rect.width - inset, y: rect.height - inset),
                CGPoint(x: rect.width - inset, y: rect.height),
                CGPoint(x: inset, y: rect.height),
                CGPoint(x: inset, y: rect.height - inset),
                CGPoint(x: 0, y: rect.height - inset),
                CGPoint(x: 0, y: inset),
                CGPoint(x: inset, y: inset)
            ])
            path.closeSubpath()
        }
    }
}
