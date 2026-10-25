import SwiftUI

struct AvatarPickerView: View {
    @Binding var selection: String
    let spriteName: String
    let onChoose: () -> Void
    @State private var preview: CompanionAppearance = .pebble

    private var selected: CompanionAppearance {
        .resolve(savedID: selection, spriteAvailable: CompanionAvatar.spriteAvailable)
    }

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $preview) {
                ForEach(CompanionAppearance.available(spriteAvailable: CompanionAvatar.spriteAvailable)) { appearance in
                    page(for: appearance)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .tag(appearance)
                }
            }
            .tabViewStyle(.verticalPage)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .sensitiveContent(placeholder: "Avatars hidden")
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { preview = selected }
        .accessibilityIdentifier("avatar.picker")
    }

    private func page(for appearance: CompanionAppearance) -> some View {
        VStack(spacing: 2) {
            CompanionAvatar(appearance: appearance, animation: .idle, level: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
            Text(appearance.displayName(spriteName: spriteName))
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                selection = appearance.rawValue
                onChoose()
            } label: {
                Text(appearance == selected ? "Selected" : "Choose")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appearance == selected ? .gray : .accentColor)
            .accessibilityLabel(appearance == selected
                ? "Selected, \(appearance.displayName(spriteName: spriteName))"
                : "Choose \(appearance.displayName(spriteName: spriteName))")
            .accessibilityIdentifier("avatar.choose.\(appearance.rawValue)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }
}
