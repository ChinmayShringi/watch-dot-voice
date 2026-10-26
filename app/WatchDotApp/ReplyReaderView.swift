import SwiftUI

struct ReplyReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons
    let replies: [ChatMessage]
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(replies) { reply in
                        if reply.id != replies.first?.id { Divider() }
                        Text(reply.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("reply.text")
                    }
                    Button("Done", action: close)
                        .accessibilityIdentifier("reply.done")
                }
                .padding(.horizontal, 8)
                .sensitiveContent(placeholder: nil)
            }
            .overlay {
                if !isContentVisible {
                    Text("Reply hidden")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .unredacted()
                        .allowsHitTesting(false)
                }
            }
            .navigationTitle("Reply")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!isContentVisible)
                    .accessibilityLabel("Back to avatar")
                    .accessibilityIdentifier("reply.close")
                }
            }
        }
        .background(.black)
        .accessibilityIdentifier("reply.reader")
    }

    private var isContentVisible: Bool {
        SensitiveContentPolicy.isVisible(isActive: scenePhase == .active,
            luminanceReduced: luminanceReduced, privacyRedacted: redactionReasons.contains(.privacy))
    }
}

struct AvatarMenuView: View {
    @ObservedObject var session: ConversationSession
    @ObservedObject var catalog: PetCatalogSession
    @Binding var appearanceID: String
    let textTitle: String
    let showTextInput: () -> Void
    let showSettings: () -> Void
    let choseAvatar: () -> Void

    var body: some View {
        List {
            Button(action: showTextInput) {
                Label(textTitle, systemImage: "keyboard")
            }
            .accessibilityIdentifier("avatar.menu.text")
            NavigationLink {
                ConversationView(session: session).navigationTitle("History")
            } label: {
                Label("History", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("avatar.menu.history")
            NavigationLink {
                AvatarPickerView(selection: $appearanceID, catalog: catalog, spriteName: session.transportName,
                                 onChoose: choseAvatar)
            } label: {
                Label("Change Avatar", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("avatar.menu.appearance")
            Button(action: showSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("avatar.menu.settings")
        }
        .navigationTitle("Options")
    }
}
