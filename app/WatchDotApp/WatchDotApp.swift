import SwiftUI
import WidgetKit

@main
struct WatchDotApp: App {
    @WKApplicationDelegateAdaptor(WatchDotDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: ConversationSession
    @StateObject private var connection: ConnectionSession

    private var isLayoutPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains { ["--preview-chat", "--preview-reply", "--preview-refresh"].contains($0) }
        #else
        false
        #endif
    }

    init() {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("WatchDot", isDirectory: true)
        // Demo and real account/room histories remain in different stores.
        var demoFile = "demo-conversation.json"
        #if DEBUG && targetEnvironment(simulator)
        let previewRefresh = ProcessInfo.processInfo.arguments.contains("--preview-refresh")
        let previewReply = ProcessInfo.processInfo.arguments.contains("--preview-reply")
        let previewChat = ProcessInfo.processInfo.arguments.contains("--preview-chat") || previewRefresh || previewReply
        if previewChat { demoFile = "layout-preview.json" }
        #endif
        let store = FileConversationStore(url: directory.appendingPathComponent(demoFile))
        #if DEBUG && targetEnvironment(simulator)
        if previewChat {
            let messages = ProcessInfo.processInfo.arguments.contains("--preview-refresh-short")
                ? [ChatMessage(role: .assistant, text: "Test message.")]
                : [
                ChatMessage(role: .user, text: "I'm testing the chat layout on the watch."),
                ChatMessage(role: .assistant, text: "Demo view. Chat messages will appear here.")
            ]
            try? store.save(ConversationSnapshot(version: 1, conversationID: UUID(), messages: messages,
                pendingRequest: nil, hasAttemptedDelivery: false, deliveryState: .idle, draft: ""))
        }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let transport: any ChatTransport
        if previewRefresh {
            transport = RefreshPreviewTransport(messages: (try? store.load())?.messages ?? [])
        } else if previewChat {
            transport = AvatarPreviewTransport()
        } else {
            transport = DemoChatTransport()
        }
        #else
        let transport: any ChatTransport = DemoChatTransport()
        #endif
        let session = ConversationSession(transport: transport, store: store)
        #if DEBUG && targetEnvironment(simulator)
        if previewRefresh { session.resumeAutomatically() }
        if previewReply { session.send("Show a long sample reply.") }
        #endif
        _session = StateObject(wrappedValue: session)
        let bridge = CompanionConnectivity()
        let connection = ConnectionSession(store: KeychainSignInStore(),
            chatDirectory: directory.appendingPathComponent("direct", isDirectory: true),
            backgroundReceiver: WatchBackgroundReceiver.shared, companion: bridge)
        #if DEBUG && targetEnvironment(simulator)
        if previewChat { connection.selectDemo(true) }
        #endif
        bridge.receive = { [weak connection] message in
            await connection?.receiveCompanionMessage(message) ?? .idle
        }
        bridge.requestFailed = { [weak connection] in connection?.companionRequestFailed() }
        bridge.activate()
        _connection = StateObject(wrappedValue: connection)
        refreshComplicationImageIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ChatRootView(connection: connection, demo: session)
                #if DEBUG && targetEnvironment(simulator)
                .layoutPrivacyPreview(enabled: isLayoutPreview)
                #endif
                .onAppear {
                    if scenePhase == .active && !isLayoutPreview {
                        connection.enterForeground()
                        refreshComplicationImageIfNeeded()
                    }
                }
                .onChange(of: connection.demoEnabled) { _, enabled in
                    if !enabled { session.suspend() }
                }
                .onChange(of: connection.phase) { _, _ in connectChatIfReady() }
                .onChange(of: connection.dotProbeState) { _, state in
                    if case .located = state { session.suspend() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard !isLayoutPreview else { return }
                    if phase == .background {
                        session.suspend()
                        connection.enterBackground()
                    } else if phase == .active {
                        connection.enterForeground()
                        refreshComplicationImageIfNeeded()
                    }
                }
        }
    }
    private func refreshComplicationImageIfNeeded() {
        // One refresh per icon revision; the launcher still has no periodic timeline.
        let key = "WatchDot.complicationIconRevision"
        guard UserDefaults.standard.integer(forKey: key) < 7 else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: "cl.australapps.watchdot.launcher")
        #if DEBUG
        WidgetCenter.shared.getCurrentConfigurations { result in
            let record: [String: Any]
            switch result {
            case .success(let widgets):
                record = ["revision": 7, "widgets": widgets.map { ["kind": $0.kind, "family": $0.family.rawValue] as [String: Any] }]
            case .failure:
                record = ["revision": 7, "status": "unavailable"]
            }
            if let data = try? JSONSerialization.data(withJSONObject: record, options: .sortedKeys) {
                try? data.write(to: URL.cachesDirectory.appendingPathComponent("watchdot-widget-configurations.json"), options: .atomic)
            }
        }
        #endif
        UserDefaults.standard.set(7, forKey: key)
    }

    private func connectChatIfReady() {
        if !isLayoutPreview, scenePhase == .active, connection.phase == .signedIn, connection.dotProbeState == .idle {
            connection.probeDotAccess()
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
private struct AvatarPreviewTransport: ChatTransport {
    let displayName = "Companion"
    let isRealConnection = false
    let supportsIdempotentRetry = true

    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        if ProcessInfo.processInfo.arguments.contains("--preview-reply") {
            await onAccepted()
            try await Task.sleep(for: .seconds(2))
            return ChatMessage(role: .assistant, text: "Here's your day at a glance.\n\nStart with one clear priority. Give it an uninterrupted block of time, then take a short break.\n\nKeep the next step small enough to begin now. Write down what you need, remove distractions, and check your progress after the first block.\n\nYou can turn the Digital Crown or swipe to read a longer reply. Your message stays in History after you return to the avatar.\n\nWhen you're ready, tap Done or the close button above.")
        }
        return try await DemoChatTransport().send(request, onAccepted: onAccepted)
    }
}

/// An offline fixture for exercising pull, release and loading without a real account.
private actor RefreshPreviewTransport: ChatTransport {
    let displayName = "Local preview"
    let isRealConnection = true
    let supportsHistorySync = true
    private var messages: [ChatMessage]
    private var reads = 0

    init(messages: [ChatMessage]) { self.messages = messages }

    func recentMessages(limit: Int) async throws -> [RoomMessage] {
        reads += 1
        try await Task.sleep(for: .seconds(4))
        messages.append(ChatMessage(role: .assistant, text: "Local check \(reads): messages updated."))
        return messages.map { RoomMessage(remoteID: $0.id.uuidString, message: $0, requestID: nil, replyTo: nil) }
    }

    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        throw ChatTransportError.rejected("Sync preview: sending disabled.")
    }
}
#endif

/// An unavailable real transport is a connection screen, never an implicit demo session.
private struct ChatRootView: View {
    @ObservedObject var connection: ConnectionSession
    @ObservedObject var demo: ConversationSession
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            Group {
                if let session = connection.selectedConversation(demo: demo) {
                    selectedContent(session: session).id(session.conversationID)
                } else {
                    VStack(spacing: 10) {
                        ScrollView {
                            VStack(spacing: 8) {
                                Text(connection.chatBlockReason).font(.footnote)
                                if connection.phase.isBusy || connection.dotProbeState == .checking {
                                    ProgressView()
                                    Button("View connection") { showConnection = true }
                                } else {
                                    Button(connection.phase == .signedIn ? "Connect to your Dot" : connection.actionTitle) {
                                        if connection.phase == .signedIn { connection.probeDotAccess() }
                                        else if connection.isConfigured {
                                            connection.connect()
                                            showConnection = true
                                        } else { showConnection = true }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .sensitiveContent(placeholder: "Connection hidden")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if connection.selectedConversation(demo: demo) == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        ChatHeader(name: connection.directConversation?.transportName ?? "Dot",
                                   color: connectionColor, status: connection.phase.title) {
                            showConnection = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showConnection) {
            ConnectionView(connection: connection, session: connection.selectedConversation(demo: demo) ?? demo)
        }
    }

    @ViewBuilder
    private func selectedContent(session: ConversationSession) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-refresh") {
            ConversationView(session: session)
        } else {
            avatarHome(session: session)
        }
        #else
        avatarHome(session: session)
        #endif
    }

    private func avatarHome(session: ConversationSession) -> some View {
        AvatarConversationView(session: session, connection: connection,
            isSettingsPresented: showConnection) { showConnection = true }
    }

    private var connectionColor: Color {
        switch connection.phase {
        case .signedIn: .green
        case .connecting, .awaitingConsent, .verifying, .paused, .expired: .orange
        case .failed: .red
        case .setupRequired, .signedOut, .cancelled: .gray
        }
    }
}

/// The whole header opens connection details inside the system toolbar's hit area.
private struct ChatHeader: View {
    let name: String
    let color: Color
    let status: String
    let showDetails: () -> Void

    var body: some View {
        Button(action: showDetails) {
            HStack(spacing: 4) {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 60, alignment: .leading)
                Circle().fill(color).frame(width: 6, height: 6)
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), connection details")
        .accessibilityValue(status)
        .sensitiveContent(placeholder: "Dot")
    }
}

struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.redactionReasons) private var redactionReasons
    @ObservedObject var session: ConversationSession
    @State private var bottomPosition = CGFloat.greatestFiniteMagnitude
    @State private var scrollPolicy = HistoryScrollPolicy()
    @State private var scrollRequest = UUID()
    @State private var refreshGestureState = MessageRefreshGestureState()
    @FocusState private var inputFocused: Bool
    var focusInputOnAppear = false

    var body: some View {
        VStack(spacing: 4) {
            if !session.isRealConnection {
                Text("DEMO")
                    .font(.caption2).foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if session.messages.isEmpty {
                                Text(session.isRealConnection
                                     ? "Your conversation starts here."
                                     : "This demo stays on your watch. Connect from Settings to message your Dot.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(session.messages) { message in
                                MessageBubble(message: message, pending: session.pendingMessageIDs.contains(message.id),
                                              assistantName: session.isRealConnection ? session.transportName : "Demo")
                            }
                            statusView
                            if let issue = session.storageIssue {
                                Text(issue).font(.caption2).foregroundStyle(.red)
                                if session.canRetrySaving {
                                    Button("Save again", action: session.retrySaving).font(.caption2)
                                }
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }
                        .frame(minHeight: viewport.size.height, alignment: .bottom)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ChatHistoryLayout.self,
                                value: HistoryScrollLayout(revision: contentRevision,
                                    contentHeight: geometry.size.height, viewportHeight: viewport.size.height,
                                    bottom: geometry.frame(in: .named("chat-scroll")).maxY))
                        })
                    }
                    .coordinateSpace(name: "chat-scroll")
                    .onPreferenceChange(ChatHistoryLayout.self) { layout in
                        guard let layout, layout.revision == contentRevision else { return }
                        bottomPosition = layout.bottom
                        let shouldFollow = scrollPolicy.shouldFollow(layout)
                        scrollPolicy = scrollPolicy.observing(layout)
                        if shouldFollow && isContentVisible { scrollToLatest(proxy) }
                    }
                    .modifier(ChatRefreshObservation(session: session, gestureState: $refreshGestureState,
                        bottomPosition: bottomPosition, viewportHeight: viewport.size.height,
                        interactionChanged: { scrollPolicy = scrollPolicy.interacting($0) },
                        legacyGesture: refreshGesture(atBottom: bottomPosition <= viewport.size.height + 2)))
                    .overlay(alignment: .bottom) {
                        if session.isRealConnection && (refreshGestureState.pullDistance > 0 || refreshGestureState.isArmed || session.isSynchronizing) {
                            Group {
                                if session.isSynchronizing { ProgressView().controlSize(.mini) }
                                else {
                                    Image(systemName: "arrow.clockwise")
                                        .rotationEffect(.degrees(min(refreshGestureState.pullDistance / refreshThreshold, 1) * 180))
                                        .foregroundStyle(refreshGestureState.isArmed ? .green : .white)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.9), in: Circle())
                            .allowsHitTesting(false)
                            .accessibilityLabel(session.isSynchronizing ? "Checking for new messages"
                                : refreshGestureState.isArmed ? "Release to refresh" : "Swipe up to refresh")
                        }
                    }
                    .accessibilityAction(named: Text("Sync messages")) { session.refreshFromGesture() }
                    .overlay(alignment: .bottom) {
                        if !scrollPolicy.followsLatest {
                            Button("Latest", systemImage: "arrow.down", action: jumpToLatest)
                                .font(.footnote)
                                .buttonStyle(.borderedProminent)
                                .fixedSize()
                                .accessibilityLabel("Latest messages")
                                .accessibilityIdentifier("history.latest")
                        }
                    }
                    .onChange(of: scrollRequest) { _, _ in scrollToLatest(proxy) }
                    .onChange(of: isContentVisible) { _, visible in
                        if visible && scrollPolicy.followsLatest { scrollToLatest(proxy) }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Message", text: $session.draft)
                    .focused($inputFocused)
                    .font(.footnote)
                    .controlSize(.small)
                    .submitLabel(.done)
                    .accessibilityLabel("Message: dictation or native keyboard")
                    .disabled(!session.canEditDraft)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                        .frame(minWidth: 38, minHeight: 38)
                }
                .buttonStyle(.plain)
                .disabled(session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.canSend)
                .accessibilityLabel(session.isRealConnection ? "Send message to Dot" : "Send demo message")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 8)
        .ignoresSafeArea(.container, edges: .bottom)
        .sensitiveContent(placeholder: "History hidden")
        .onChange(of: isContentVisible) { _, visible in
            if !visible {
                inputFocused = false
                refreshGestureState.cancel()
                scrollPolicy = scrollPolicy.interacting(false)
            }
        }
        .onAppear { inputFocused = focusInputOnAppear && isContentVisible }
        .task(id: session.conversationID) {
            if scenePhase == .active, !session.isRealConnection { session.resumeAutomatically() }
        }
    }

    private var isContentVisible: Bool {
        SensitiveContentPolicy.isVisible(isActive: scenePhase == .active,
            luminanceReduced: luminanceReduced, privacyRedacted: redactionReasons.contains(.privacy))
    }

    private var contentRevision: Int {
        var revision = Hasher()
        for message in session.messages {
            revision.combine(message.id)
            revision.combine(message.text)
        }
        revision.combine(String(describing: session.deliveryState))
        revision.combine(session.storageIssue)
        revision.combine(session.synchronizationIssue)
        revision.combine(session.isSynchronizing)
        revision.combine(session.pendingMessageIDs)
        return revision.finalize()
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard isContentVisible else { return }
        // Immediate following avoids moving text beneath a reader or VoiceOver focus.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("latest", anchor: .bottom) }
    }

    private func jumpToLatest() {
        scrollPolicy = scrollPolicy.jumpingToLatest()
        scrollRequest = UUID()
    }

    @ViewBuilder
    private var statusView: some View {
        if session.isSynchronizing {
            Text("Syncing…").font(.caption2).foregroundStyle(.secondary)
        } else if let issue = session.synchronizationIssue {
            Text(issue).font(.caption2).foregroundStyle(.orange)
        }
        switch session.deliveryState {
        case .idle:
            EmptyView()
        case .answered:
            if session.followUpUntil != nil {
                Text("Refresh to see messages from your Dot's other clients").font(.caption2).foregroundStyle(.secondary)
            }
        case .sending, .waiting:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(session.isRealConnection
                         ? (session.deliveryState == .sending ? "Connecting to your Dot…" : "Waiting for your Dot…")
                         : (session.deliveryState == .sending ? "Sending demo…" : "Waiting for demo…"))
                }
            }
            .font(.caption2)
        case .waitingForConnection:
            Text(session.isRealConnection ? "Offline. The message is still pending." : "Offline (simulated). The message is still pending.").font(.caption2)
        case .cancelled:
            if session.showsCancellationNotice {
                Text("Wait canceled. This doesn't confirm a cancellation on the service.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            recoveryActions
        case .failed(let reason):
            Text(reason).font(.caption2).foregroundStyle(.orange)
            recoveryActions
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.canRetry && !session.retryIsReadOnly {
                Button("Resume message", action: session.retry)
            }
            if session.canDiscard {
                Button(session.isRealConnection ? "Discard unsent" : "Discard demo", action: session.discardFailedTurn)
            }
        }
        .font(.caption2)
    }

    private var refreshThreshold: Double {
        // Native overscroll is rubber-banded; it is shorter than the finger's travel.
        if #available(watchOS 11.0, *) { return 28 }
        return 56
    }

    // Compatibility for watchOS 10, which has no native scroll observation API.
    private func refreshGesture(atBottom: Bool) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                scrollPolicy = scrollPolicy.interacting(true)
                if !refreshGestureState.isTracking {
                    refreshGestureState.begin(enabled: atBottom && session.isRealConnection && !session.isSynchronizing,
                                              threshold: refreshThreshold)
                }
                guard -value.translation.height > abs(value.translation.width) else { return }
                refreshGestureState.update(distance: -value.translation.height)
            }
            .onEnded { _ in
                scrollPolicy = scrollPolicy.interacting(false)
                if refreshGestureState.release() { session.refreshFromGesture() }
            }
    }

    private func send() {
        if session.send(session.draft) { jumpToLatest() }
    }

}

private struct ChatHistoryLayout: PreferenceKey {
    static let defaultValue: HistoryScrollLayout? = nil
    static func reduce(value: inout HistoryScrollLayout?, nextValue: () -> HistoryScrollLayout?) {
        value = nextValue() ?? value
    }
}

/// Observe native scrolling without installing a competing pan recognizer on watchOS 11+.
private struct ChatRefreshObservation<LegacyGesture: Gesture>: ViewModifier {
    @ObservedObject var session: ConversationSession
    @Binding var gestureState: MessageRefreshGestureState
    let bottomPosition: CGFloat
    let viewportHeight: CGFloat
    let interactionChanged: (Bool) -> Void
    let legacyGesture: LegacyGesture
    @State private var interacting = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content
                .scrollBounceBehavior(.always, axes: .vertical)
                .onScrollPhaseChange { oldPhase, phase, context in
                    interactionChanged(phase != .idle && phase != .animating)
                    if phase == .tracking || phase == .interacting {
                        if !gestureState.isTracking {
                            gestureState.begin(enabled: session.isRealConnection && !session.isSynchronizing)
                        }
                        if phase == .interacting {
                            gestureState.update(distance: max(viewportHeight - bottomPosition,
                                                              overscroll(context.geometry)))
                        }
                    } else if oldPhase == .interacting && (phase == .decelerating || phase == .idle) {
                        // The preference can be one layout pass behind the final touch sample.
                        gestureState.update(distance: overscroll(context.geometry))
                        if gestureState.release() { session.refreshFromGesture() }
                    } else if phase == .idle || phase == .animating {
                        gestureState.cancel()
                    }
                    interacting = phase == .interacting
                }
                .onChange(of: bottomPosition) { _, bottom in
                    guard interacting, !session.isSynchronizing else { return }
                    gestureState.update(distance: viewportHeight - bottom)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: overscroll) { _, distance in
                    guard interacting, !session.isSynchronizing else { return }
                    gestureState.update(distance: distance)
                }
                .onChange(of: session.isSynchronizing) { _, refreshing in
                    if refreshing { gestureState.cancel() }
                }
                .onDisappear { gestureState.cancel(); interactionChanged(false) }
        } else {
            content.simultaneousGesture(legacyGesture)
        }
    }

    @available(watchOS 11.0, *)
    private func overscroll(_ geometry: ScrollGeometry) -> CGFloat {
        // watchOS includes the top navigation inset in contentSize. Subtract it once.
        let bottom = max(-geometry.contentInsets.top, geometry.contentSize.height -
            geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height)
        return max(0, geometry.contentOffset.y - bottom)
    }
}

private struct ConnectionView: View {
    @ObservedObject var connection: ConnectionSession
    @ObservedObject var session: ConversationSession
    @Environment(\.dismiss) private var dismiss
    @State private var historyLimit = ChatHistorySettings.limit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(connection.phase.title).font(.headline)
                Text("Rillby · Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    .font(.caption2).foregroundStyle(.secondary)
                if let account = connection.accountLabel { Text(account) }
                if case .failed(let reason) = connection.phase {
                    Text(reason).foregroundStyle(.orange)
                }
                if connection.phase == .awaitingConsent {
                    Text("Open Rillby on your iPhone and finish authorizing in the browser. The session will reach the watch automatically.")
                }
                if connection.isRenewingSession {
                    ProgressView("Renewing session…")
                } else if connection.phase.isBusy {
                    ProgressView()
                    Button("Cancel authorization", action: connection.cancel)
                } else if connection.phase != .signedIn {
                    Button(connection.actionTitle, action: connection.connect)
                    if connection.canResume {
                        Button("Cancel authorization", action: connection.cancel)
                    }
                }
                Text(connection.phase == .signedIn
                     ? "Your account is connected. Direct chat is experimental."
                     : "Authorize your account from Rillby on your iPhone. The chat with your Dot runs on the watch.")
                    .foregroundStyle(.secondary)

                if connection.phase == .signedIn {
                    if connection.canRenewSession {
                        Text("Automatic renewal on.").font(.caption2)
                    } else {
                        Text("Authorize once more to turn on automatic renewal for this session.")
                            .font(.caption2)
                        Button("Turn on automatic renewal", action: connection.connect)
                    }
                    dotAccessProbe
                }

                if connection.accountLabel != nil {
                    Button("Sign out on this watch", action: connection.signOutLocally)
                }
                Divider()
                Picker("Messages per sync", selection: $historyLimit) {
                    ForEach(ChatHistorySettings.limits, id: \.self) { Text("\($0)").tag($0) }
                }
                .onChange(of: historyLimit) { _, value in ChatHistorySettings.limit = value }
                Text("Replies sync while you wait. To check again, pull up at the end of History. Delivery may be delayed when your wrist is down.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Back to avatar") { dismiss() }
            }
            .font(.footnote)
            .padding(.horizontal, 8)
        }
        .sensitiveContent(placeholder: "Account details hidden")
        .onAppear { connection.refresh() }
    }

    private var dotAccessProbe: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection").font(.headline)
            if connection.dotProbeState == .checking {
                ProgressView("Checking OpenAI…")
                Button("Cancel check", action: connection.cancelDotProbe)
            } else {
                Button("Check connection", action: connection.probeDotAccess)
            }
            switch connection.dotProbeState {
            case .idle:
                Text("Check that your watch can reach your Dot.")
            case .checking:
                EmptyView()
            case .cancelled:
                Text("Check canceled. You can run it again.")
            case .located(let dot):
                Text("Connected to \(dot.name ?? "your Dot").")
                Text(session.isRealConnection
                     ? "Your Dot is available."
                     : "Preparing your conversation…")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
            }

        }
        .font(.caption2)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let pending: Bool
    let assistantName: String

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 14) }
            VStack(alignment: .leading, spacing: 3) {
                Text(message.role == .user ? "You" : assistantName)
                    .font(.caption2).foregroundStyle(.secondary)
                Text(message.text).font(.footnote)
                if pending { Text("Pending").font(.caption2).foregroundStyle(.orange) }
                HStack(spacing: 4) {
                    Text(message.timestampLabel())
                        .monospacedDigit()
                        .foregroundStyle(Color(white: 0.55))
                    if message.role == .assistant {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(red: 0.20, green: 0.72, blue: 0.95))
                            .accessibilityLabel("Message received")
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
            }
            .padding(8)
            .background(message.role == .user ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 14) }
        }
        .frame(maxWidth: .infinity)
    }
}
