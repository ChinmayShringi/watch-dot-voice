import Foundation

/// Runtime presentation only. History hydration and dismissed replies never reopen the reader.
public struct AvatarPresentation: Equatable, Sendable {
    public let visibleReplies: [ChatMessage]
    public let pendingReplies: [ChatMessage]
    public let seenIDs: Set<UUID>
    public let isDismissing: Bool

    public init(baselineReplies: [ChatMessage] = []) {
        self.init(visibleReplies: [], pendingReplies: [], seenIDs: Set(baselineReplies.map(\.id)),
                  isDismissing: false)
    }

    private init(visibleReplies: [ChatMessage], pendingReplies: [ChatMessage], seenIDs: Set<UUID>,
                 isDismissing: Bool) {
        self.visibleReplies = visibleReplies
        self.pendingReplies = pendingReplies
        self.seenIDs = seenIDs
        self.isDismissing = isDismissing
    }

    public func receiving(_ replies: [ChatMessage], canPresent: Bool) -> Self {
        replies.reduce(self) { state, reply in state.receiving(reply) }
            .presentingPending(ifAllowed: canPresent)
    }

    public func presentingPending(ifAllowed allowed: Bool) -> Self {
        guard allowed, !isDismissing, !pendingReplies.isEmpty else { return self }
        return Self(visibleReplies: visibleReplies + pendingReplies, pendingReplies: [], seenIDs: seenIDs,
                    isDismissing: isDismissing)
    }

    public func dismissing() -> Self {
        guard !isDismissing, !visibleReplies.isEmpty else { return self }
        return Self(visibleReplies: [], pendingReplies: pendingReplies, seenIDs: seenIDs,
                    isDismissing: true)
    }

    /// Promotion waits for the native cover's dismissal animation, not its binding change.
    public func dismissalCompleted(canPresent: Bool) -> Self {
        guard isDismissing else { return self }
        return Self(visibleReplies: [], pendingReplies: pendingReplies, seenIDs: seenIDs,
                    isDismissing: false).presentingPending(ifAllowed: canPresent)
    }

    private func receiving(_ reply: ChatMessage) -> Self {
        guard reply.role == .assistant,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        if visibleReplies.contains(where: { $0.id == reply.id }) {
            return Self(visibleReplies: replacing(reply, in: visibleReplies),
                        pendingReplies: pendingReplies, seenIDs: seenIDs, isDismissing: isDismissing)
        }
        if pendingReplies.contains(where: { $0.id == reply.id }) {
            return Self(visibleReplies: visibleReplies, pendingReplies: replacing(reply, in: pendingReplies),
                        seenIDs: seenIDs, isDismissing: isDismissing)
        }
        guard !seenIDs.contains(reply.id) else { return self }
        return Self(visibleReplies: visibleReplies, pendingReplies: pendingReplies + [reply],
                    seenIDs: seenIDs.union([reply.id]), isDismissing: isDismissing)
    }

    private func replacing(_ reply: ChatMessage, in replies: [ChatMessage]) -> [ChatMessage] {
        replies.map { $0.id == reply.id ? reply : $0 }
    }
}
