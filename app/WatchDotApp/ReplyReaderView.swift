import SwiftUI

struct ReplyReaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    let replies: [ChatMessage]
    let name: String
    let close: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if scenePhase == .active && !luminanceReduced {
                        ForEach(replies) { reply in
                            if reply.id != replies.first?.id { Divider() }
                            Text(reply.text)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("reply.text")
                        }
                    } else {
                        Text("Reply hidden").foregroundStyle(.secondary)
                    }
                    Button("Done", action: close)
                        .accessibilityIdentifier("reply.done")
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle(name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Back to avatar")
                    .accessibilityIdentifier("reply.close")
                }
            }
        }
        .background(.black)
        .accessibilityIdentifier("reply.reader")
    }
}

struct AvatarMenuView: View {
    @ObservedObject var session: ConversationSession
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
                AvatarPickerView(selection: $appearanceID, spriteName: session.transportName,
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
