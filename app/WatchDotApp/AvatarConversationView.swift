import SwiftUI
import WatchKit

struct AvatarConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @ObservedObject var session: ConversationSession
    @ObservedObject var connection: ConnectionSession
    @StateObject private var voice: VoiceInputSession
    @AppStorage("companion.appearance") private var appearanceID = "sprite"
    @State private var presentation: AvatarPresentation
    @State private var destination: Destination?
    @State private var sheetVisible = false
    @State private var voiceFailure: VoiceFailure?
    @State private var retryAfterDismiss = false
    @State private var settingsAfterDismiss = false
    @State private var isQuiet = false
    @State private var activityID = UUID()
    let isSettingsPresented: Bool
    let showSettings: () -> Void

    private enum Destination: String, Identifiable {
        case menu, text, voiceError
        var id: String { rawValue }
    }

    private struct VoiceFailure {
        let message: String
        let transcript: String?
    }

    init(session: ConversationSession, connection: ConnectionSession,
         isSettingsPresented: Bool = false, showSettings: @escaping () -> Void) {
        self.session = session
        self.connection = connection
        self.isSettingsPresented = isSettingsPresented
        self.showSettings = showSettings
        _presentation = State(initialValue: AvatarPresentation(baselineReplies: session.receivedReplies))
        _voice = StateObject(wrappedValue: VoiceInputSession(recorder: WatchVoiceRecorder(),
            prepare: connection.makeVoiceTurn))
    }

    var body: some View {
        VStack(spacing: 4) {
            if !session.isRealConnection {
                Text("DEMO").font(.caption2).foregroundStyle(.orange)
            }
            avatarButton.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isQuiet && isContentVisible {
                Text(appearance.displayName(spriteName: session.transportName))
                    .font(.footnote.weight(.medium)).lineLimit(1)
                    .accessibilityIdentifier("avatar.name")
            }
            status
            if captureBusy {
                Button("Cancel") { voice.cancel(); noteActivity() }
                    .font(.footnote).buttonStyle(.plain).frame(minHeight: 32)
                    .accessibilityIdentifier("avatar.cancel")
            }
        }
        .padding(.horizontal, 8)
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { noteActivity(); destination = .menu } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(captureBusy || session.deliveryState == .sending)
                .accessibilityLabel("Options")
                .accessibilityHint("Text input, history, avatar and settings")
                .accessibilityIdentifier("avatar.menu")
            }
        }
        .sheet(item: $destination, onDismiss: sheetDismissed) { selected in
            NavigationStack {
                switch selected {
                case .menu:
                    AvatarMenuView(session: session, appearanceID: $appearanceID,
                        textTitle: voiceFailure?.transcript == nil ? "Type a Message" : textInputTitle,
                        showTextInput: openTextInput,
                        showSettings: { settingsAfterDismiss = true; destination = nil },
                        choseAvatar: { destination = nil })
                case .text:
                    ConversationView(session: session, focusInputOnAppear: true).navigationTitle("Message")
                case .voiceError:
                    voiceErrorDetails
                }
            }
        }
        .fullScreenCover(isPresented: replyPresented, onDismiss: replyDismissed) {
            ReplyReaderView(replies: presentation.visibleReplies, name: session.transportName,
                            close: closeReply)
        }
        .onChange(of: session.receivedReplies) { _, replies in
            presentation = presentation.receiving(replies, canPresent: canPresentReply)
        }
        .onChange(of: destination) { _, selected in
            if selected != nil { sheetVisible = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { retryAfterDismiss = false; voice.cancel() }
            else { noteActivity(); presentPendingReply() }
        }
        .onChange(of: luminanceReduced) { _, reduced in
            if !reduced { presentPendingReply() }
        }
        .onChange(of: connection.voiceGeneration) { _, _ in
            // Background cancellation invalidates voice work, not unread replies.
            voice.cancel()
            retryAfterDismiss = false
            voiceFailure = nil
        }
        .onChange(of: session.conversationID) { _, _ in resetPresentation() }
        .onChange(of: voice.phase) { previous, phase in
            if isContentVisible {
                if phase == .listening { WKInterfaceDevice.current().play(.start) }
                else if phase == .failed { WKInterfaceDevice.current().play(.failure) }
                else if previous == .listening { WKInterfaceDevice.current().play(.stop) }
            }
            if phase == .failed, let message = voice.errorMessage {
                voiceFailure = VoiceFailure(message: message, transcript: voice.retainedTranscript)
            }
            noteActivity()
            presentPendingReply()
        }
        .onChange(of: session.deliveryState) { _, _ in
            noteActivity()
            presentPendingReply()
        }
        .onChange(of: isSettingsPresented) { _, shown in
            if !shown { noteActivity(); presentPendingReply() }
        }
        .onDisappear {
            // A reply cover also hides the home. It must not reset the presentation queue.
            if captureBusy { retryAfterDismiss = false; voice.cancel() }
        }
        .task(id: activityID) {
            guard canBecomeQuiet else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard canBecomeQuiet else { return }
            isQuiet = true
        }
        .task(id: session.conversationID) {
            if scenePhase == .active, !session.isRealConnection { session.resumeAutomatically() }
        }
    }

    private var appearance: CompanionAppearance {
        CompanionAppearance.resolve(savedID: appearanceID, spriteAvailable: CompanionAvatar.spriteAvailable)
    }

    private var avatarButton: some View {
        Button {
            noteActivity()
            if session.isRealConnection { voiceFailure = nil; voice.tap() }
            else { openTextInput() }
        } label: {
            CompanionAvatar(appearance: appearance, animation: avatarAnimation, level: voice.level)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isContentVisible || voice.phase == .requesting || voice.phase == .transcribing ||
                  (voice.phase != .listening && !session.canSend))
        .accessibilityLabel(voice.phase == .listening ? "Stop recording and send"
                            : appearance.displayName(spriteName: session.transportName))
        .accessibilityHint(session.isRealConnection ? "Double-tap to speak" : "Opens local demo text input")
        .accessibilityIdentifier("avatar.talk")
    }

    @ViewBuilder private var status: some View {
        if !isContentVisible {
            Text("Tap to speak").font(.footnote).foregroundStyle(.secondary)
        } else if let failure = voiceFailure {
            Button { destination = .voiceError } label: {
                Text(failure.message).font(.footnote).foregroundStyle(.orange).lineLimit(2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(failure.message) Show voice input details")
            .accessibilityIdentifier("avatar.error")
        } else {
            Text(statusText).font(.footnote)
                .foregroundStyle(voice.phase == .listening ? .red : .secondary)
                .monospacedDigit().fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("avatar.status")
        }
    }

    private var voiceErrorDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if isContentVisible {
                    Text(voiceFailure?.message ?? "Voice input is unavailable.")
                    if let transcript = voiceFailure?.transcript {
                        Text(transcript).foregroundStyle(.secondary)
                        Button(session.draft.isEmpty ? "Review transcript" : "Replace draft with transcript") {
                            session.draft = transcript
                            openTextInput()
                        }
                    }
                    Button(textInputTitle, action: openTextInput)
                    Button("Try again") { retryAfterDismiss = true; destination = nil }
                        .disabled(!session.canSend)
                } else {
                    Text("Voice input details hidden")
                }
            }
            .font(.body).padding(.horizontal, 8)
        }
        .navigationTitle("Voice input")
    }

    private var captureBusy: Bool {
        voice.phase == .requesting || voice.phase == .listening || voice.phase == .transcribing
    }

    private var isContentVisible: Bool { scenePhase == .active && !luminanceReduced }

    private var canPresentReply: Bool {
        isContentVisible && !captureBusy && voiceFailure == nil && destination == nil && !sheetVisible &&
        !isSettingsPresented && !settingsAfterDismiss && !retryAfterDismiss &&
        session.deliveryState != .sending
    }

    private var canBecomeQuiet: Bool {
        isContentVisible && !captureBusy && voiceFailure == nil && destination == nil &&
        !isSettingsPresented && presentation.visibleReplies.isEmpty &&
        (session.deliveryState == .idle || session.deliveryState == .answered)
    }

    private var replyPresented: Binding<Bool> {
        Binding(get: { !presentation.visibleReplies.isEmpty }, set: { shown in
            if !shown { closeReply() }
        })
    }

    private var statusText: String {
        switch voice.phase {
        case .requesting: return "Preparing microphone"
        case .listening: return "Listening \(Int(min(voice.elapsed, 60))) / 60s"
        case .transcribing: return "Transcribing"
        case .failed: return "Voice input unavailable"
        case .idle: break
        }
        switch session.deliveryState {
        case .sending: return "Sending"
        case .waiting: return "Waiting for reply"
        case .waitingForConnection: return "Offline, message pending"
        case .failed, .cancelled: return "Open history to review delivery"
        case .idle, .answered: return session.isRealConnection ? "Tap to speak" : "Tap for demo text input"
        }
    }

    private var avatarAnimation: AvatarAnimation {
        if voiceFailure != nil { return .failed }
        switch voice.phase {
        case .listening: return .listening
        case .requesting, .transcribing: return .working
        case .failed: return .failed
        case .idle: break
        }
        switch session.deliveryState {
        case .sending, .waiting: return .working
        case .failed, .waitingForConnection: return .failed
        case .answered: return isQuiet ? .idle : .replied
        case .idle, .cancelled: return .idle
        }
    }

    private var textInputTitle: String {
        voiceFailure?.transcript == nil ? "Use text input" : "Discard voice and type"
    }

    private func noteActivity() { isQuiet = false; activityID = UUID() }

    private func openTextInput() {
        retryAfterDismiss = false
        voice.cancel()
        voiceFailure = nil
        destination = .text
        noteActivity()
    }

    private func sheetDismissed() {
        sheetVisible = false
        noteActivity()
        if settingsAfterDismiss {
            showSettings()
            settingsAfterDismiss = false
        } else if retryAfterDismiss {
            retryAfterDismiss = false
            guard isContentVisible, session.isRealConnection, session.canSend else { return }
            voiceFailure = nil
            voice.tap()
        } else { presentPendingReply() }
    }

    private func presentPendingReply() {
        presentation = presentation.presentingPending(ifAllowed: canPresentReply)
    }

    private func replyDismissed() {
        presentation = presentation.dismissalCompleted(canPresent: canPresentReply)
    }

    private func closeReply() {
        presentation = presentation.dismissing()
        noteActivity()
    }

    private func resetPresentation() {
        voice.cancel()
        voiceFailure = nil
        retryAfterDismiss = false
        settingsAfterDismiss = false
        destination = nil
        presentation = AvatarPresentation(baselineReplies: session.receivedReplies)
        noteActivity()
    }
}
