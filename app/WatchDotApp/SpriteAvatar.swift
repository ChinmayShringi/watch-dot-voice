import SwiftUI

struct SpriteAvatar: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    let animation: AvatarAnimation
    @State private var started = Date()

    private var animates: Bool { scenePhase == .active && !reduceMotion && !luminanceReduced }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width,
                            geometry.size.height * CGFloat(AvatarAnimation.cellWidth) / CGFloat(AvatarAnimation.cellHeight))
            let height = width * CGFloat(AvatarAnimation.cellHeight) / CGFloat(AvatarAnimation.cellWidth)
            TimelineView(.animation(minimumInterval: 0.05, paused: !animates)) { context in
                let state = AvatarAnimation.displayed(animation, active: scenePhase == .active,
                    reduceMotion: reduceMotion, luminanceReduced: luminanceReduced)
                let frame = animates ? state.frame(at: context.date.timeIntervalSince(started)) : 0
                Image("AvatarAtlas")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: width * CGFloat(AvatarAnimation.columns),
                           height: height * CGFloat(AvatarAnimation.rows))
                    .offset(x: -CGFloat(frame) * width, y: -CGFloat(state.row) * height)
                    .frame(width: width, height: height, alignment: .topLeading)
                    .clipped()
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .onChange(of: animation) { _, _ in started = Date() }
        .onChange(of: animates) { _, _ in started = Date() }
        .accessibilityHidden(true)
    }
}
