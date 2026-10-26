import SwiftUI
import WatchKit

struct AvatarConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons
    @ObservedObject var session: ConversationSession
    @ObservedObject var connection: ConnectionSession
    @ObservedObject private var catalog: PetCatalogSession
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
        case menu, text, voiceError, recovery
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
        _catalog = ObservedObject(wrappedValue: connection.petCatalog)
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
            status
            if captureBusy {
                Button("Cancel") { voice.cancel(); noteActivity() }
                    .font(.footnote).buttonStyle(.plain).frame(minHeight: 44)
                    .accessibilityIdentifier("avatar.cancel")
            }
        }
        .padding(.horizontal, 8)
        .background(.black)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { noteActivity(); destination = .menu } label: {
                    Image(systemName: "ellipsis").font(.body)
                }
                .buttonStyle(.plain)
                .disabled(!isContentVisible || captureBusy || session.deliveryState == .sending)
                .accessibilityLabel("Options")
                .accessibilityHint("Text input, history, avatar and settings")
                .accessibilityIdentifier("avatar.menu")
            }
        }
        .sheet(item: $destination, onDismiss: sheetDismissed) { selected in
            NavigationStack {
                switch selected {
                case .menu:
                    AvatarMenuView(session: session, catalog: catalog, appearanceID: $appearanceID,
                        textTitle: voiceFailure?.transcript == nil ? "Type a Message" : textInputTitle,
                        showTextInput: openTextInput,
                        showSettings: { settingsAfterDismiss = true; destination = nil },
                        choseAvatar: { destination = nil })
                case .text:
                    ConversationView(session: session, focusInputOnAppear: true).navigationTitle("Message")
                case .voiceError:
                    voiceErrorDetails
                case .recovery:
                    recoveryDetails
                }
            }
        }
        .fullScreenCover(isPresented: replyPresented, onDismiss: replyDismissed) {
            ReplyReaderView(replies: presentation.visibleReplies, close: closeReply)
        }
        .onChange(of: session.receivedReplies) { _, replies in
            presentation = presentation.receiving(replies, canPresent: canPresentReply)
        }
        .onChange(of: destination) { _, selected in
            if selected != nil { sheetVisible = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { retryAfterDismiss = false }
            voice.sceneChanged(to: phase == .active ? .active : phase == .background ? .background : .inactive)
            rememberVoiceFailure()
            if phase == .active { noteActivity(); presentPendingReply() }
        }
        .onChange(of: luminanceReduced) { _, reduced in
            if !reduced { presentPendingReply() }
        }
        .onChange(of: redactionReasons) { _, _ in presentPendingReply() }
        .onChange(of: connection.voiceGeneration) { _, _ in
            retryAfterDismiss = false
            if scenePhase == .background && connection.directConversation === session && connection.phase == .signedIn {
                voice.sceneChanged(to: .background)
                rememberVoiceFailure()
            } else {
                voice.cancel()
                voiceFailure = nil
            }
        }
        .onChange(of: session.conversationID) { _, _ in resetPresentation() }
        .onChange(of: voice.phase) { previous, phase in
            if isContentVisible {
                if phase == .listening { WKInterfaceDevice.current().play(.start) }
                else if phase == .failed { WKInterfaceDevice.current().play(.failure) }
                else if previous == .listening { WKInterfaceDevice.current().play(.stop) }
            }
            rememberVoiceFailure()
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
            if captureBusy {
                retryAfterDismiss = false
                voice.sceneChanged(to: .background)
                rememberVoiceFailure()
            }
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
        .task(id: appearanceID) {
            catalog.select(id: AvatarSelection.petID(from: appearanceID))
        }
    }

    private var appearance: CompanionAppearance {
        CompanionAppearance.resolve(savedID: appearanceID, spriteAvailable: CompanionAvatar.spriteAvailable)
    }

    private var avatarButton: some View {
        Button {
            noteActivity()
            if voice.phase != .listening && !session.canSend { destination = .recovery }
            else if session.isRealConnection { voiceFailure = nil; voice.tap() }
            else { openTextInput() }
        } label: {
            CompanionAvatar(appearance: appearance, animation: avatarAnimation, level: voice.level,
                atlasURL: AvatarSelection.petID(from: appearanceID).flatMap { catalog.cachedURL(for: $0) },
                playbackActive: isContentVisible && !sheetVisible && presentation.visibleReplies.isEmpty)
                .id(catalog.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isContentVisible || voice.phase == .requesting || voice.phase == .transcribing)
        .accessibilityLabel(isContentVisible ? voiceAccessibility.label : "Voice input")
        .accessibilityHint(isContentVisible ? voiceAccessibility.hint : "")
        .accessibilityValue(isContentVisible ? voiceAccessibility.value : "")
        .accessibilityIdentifier("avatar.talk")
    }

    @ViewBuilder private var status: some View {
        if !isContentVisible {
            Text("Tap to speak").font(.footnote).foregroundStyle(.secondary)
        } else if let recovery, !captureBusy {
            Button { destination = .recovery } label: {
                Text(recovery.reason).font(.footnote).foregroundStyle(.orange).lineLimit(2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recovery.reason)
            .accessibilityHint("Opens available recovery actions.")
            .accessibilityIdentifier("avatar.recovery")
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
                Text(voiceFailure?.message ?? "Voice input is unavailable.")
                if let transcript = voiceFailure?.transcript {
                    Text(transcript).foregroundStyle(.secondary)
                    Button(session.draft.isEmpty ? "Review transcript" : "Replace draft with transcript") {
                        session.draft = transcript
                        openTextInput()
                    }
                    .disabled(!session.canEditDraft)
                }
                Button(textInputTitle, action: openTextInput)
                Button(voiceFailure?.transcript == nil ? "Try Again" : "Discard and Try Again") {
                    retryAfterDismiss = true; destination = nil
                }
                .disabled(!session.canSend)
                if voiceFailure?.transcript == nil {
                    Button("Dismiss", action: dismissVoiceError)
                } else {
                    Button("Discard Transcript", role: .destructive, action: dismissVoiceError)
                }
            }
            .font(.body).padding(.horizontal, 8)
        }
        .navigationTitle("Voice input")
        .sensitiveContent(placeholder: "Voice input details hidden")
    }

    private func dismissVoiceError() {
        guard voice.dismissFailure(discardTranscript: voiceFailure?.transcript != nil) else { return }
        voiceFailure = nil
        retryAfterDismiss = false
        destination = nil
        noteActivity()
    }

    private var recoveryDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let recovery {
                    Text(recovery.reason)
                    if recovery.canSave {
                        Button("Save Again", action: session.retrySaving)
                    }
                    if let title = recovery.retryTitle {
                        Button(title, action: session.retry)
                    }
                    if recovery.canDiscard {
                        Button(session.isRealConnection ? "Discard Unsent" : "Discard Demo", role: .destructive,
                               action: session.discardFailedTurn)
                    }
                } else {
                    Text("Ready for a new message.")
                }
                Button("Connection Settings") { settingsAfterDismiss = true; destination = nil }
                Button("Done") { destination = nil }
            }
            .font(.body)
            .scenePadding(.horizontal)
        }
        .navigationTitle("Message")
        .sensitiveContent(placeholder: "Message details hidden")
        .accessibilityIdentifier("avatar.recovery.details")
    }

    private var recovery: HomeRecovery? {
        HomeRecovery(delivery: session.deliveryState, storageIssue: session.storageIssue,
            canSend: session.canSend, canRetry: session.canRetry, retryIsReadOnly: session.retryIsReadOnly,
            canDiscard: session.canDiscard, canRetrySaving: session.canRetrySaving)
    }

    private var voiceAccessibility: VoiceAccessibility {
        VoiceAccessibility(phase: voice.phase, name: session.transportName,
            elapsed: voice.elapsed, recoveryReason: session.canSend ? nil : recovery?.reason,
            isRealConnection: session.isRealConnection)
    }

    private func rememberVoiceFailure() {
        if voice.phase == .failed, let message = voice.errorMessage {
            voiceFailure = VoiceFailure(message: message, transcript: voice.retainedTranscript)
        }
    }

    private var captureBusy: Bool {
        voice.phase == .requesting || voice.phase == .listening || voice.phase == .transcribing
    }

    private var isContentVisible: Bool {
        SensitiveContentPolicy.isVisible(isActive: scenePhase == .active,
            luminanceReduced: luminanceReduced, privacyRedacted: redactionReasons.contains(.privacy))
    }

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
        case .listening: return "Listening \(Int(min(voice.elapsed, 60))) / 60s\nTap to send"
        case .transcribing: return "Transcribing"
        case .failed: return "Voice input unavailable"
        case .idle: break
        }
        switch session.deliveryState {
        case .sending: return "Sending"
        case .waiting: return "Waiting for reply"
        case .waitingForConnection: return "Offline, message pending"
        case .failed, .cancelled: return "Review message"
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
