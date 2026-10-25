import XCTest
@testable import WatchDotCore

private actor ArrivalTransport: ChatTransport {
    let displayName = "Fixture"
    let isRealConnection = false
    let supportsHistorySync = true
    let allowsSendingWhileAwaitingReply: Bool
    private let answer: ChatMessage
    private let history: [RoomMessage]
    private let followUp: [RoomMessage]

    init(answer: ChatMessage, history: [ChatMessage] = [], followUp: [ChatMessage] = [],
         allowsConcurrentInput: Bool = false, undatedIDs: Set<UUID> = []) {
        self.answer = answer
        self.allowsSendingWhileAwaitingReply = allowsConcurrentInput
        self.history = history.map(Self.roomMessage)
        self.followUp = followUp.map { message in
            RoomMessage(remoteID: message.id.uuidString, message: message, requestID: nil, replyTo: nil,
                        serverCreatedAt: undatedIDs.contains(message.id) ? nil : message.createdAt)
        }
    }

    func send(_ request: TurnRequest, onAccepted: @escaping @Sendable () async -> Void) async throws -> ChatMessage {
        await onAccepted()
        return answer
    }

    func recentMessages(limit: Int) async throws -> [RoomMessage] { history }
    func additionalMessages() async throws -> [RoomMessage] { followUp }

    private static func roomMessage(_ message: ChatMessage) -> RoomMessage {
        RoomMessage(remoteID: message.id.uuidString, message: message, requestID: nil, replyTo: nil)
    }
}

@MainActor
private final class ArrivalStore: ConversationStore {
    var snapshot: ConversationSnapshot?
    func load() throws -> ConversationSnapshot? { snapshot }
    func save(_ snapshot: ConversationSnapshot) throws { self.snapshot = snapshot }
}

@MainActor
final class ConversationArrivalTests: XCTestCase {
    func testSuccessfulTurnEmitsRuntimeReplyButRelaunchDoesNot() async {
        let answer = reply("New answer")
        let store = ArrivalStore()
        let transport = ArrivalTransport(answer: answer)
        let session = ConversationSession(transport: transport, store: store)
        XCTAssertTrue(session.send("Question"))
        await wait { session.deliveryState == .answered }
        XCTAssertEqual(session.receivedReplies, [answer])
        let restored = ConversationSession(transport: transport, store: store)
        XCTAssertTrue(restored.messages.contains(answer))
        XCTAssertTrue(restored.receivedReplies.isEmpty)
    }

    func testHistorySyncAndBackgroundReloadNeverEmitArrivals() async {
        let historical = reply("History")
        let store = ArrivalStore()
        let transport = ArrivalTransport(answer: reply("Unused"), history: [historical])
        let session = ConversationSession(transport: transport, store: store)
        session.resumeAutomatically()
        session.synchronizeRecentMessages()
        await wait { !session.isSynchronizing }
        XCTAssertEqual(session.messages, [historical])
        XCTAssertTrue(session.receivedReplies.isEmpty)
        session.reloadAfterBackground()
        XCTAssertEqual(session.messages, [historical])
        XCTAssertTrue(session.receivedReplies.isEmpty)
        session.suspend()
    }

    func testAcceptedInputsObservingSameRemoteAnswerEmitOnlyOneReply() async {
        let answer = reply("Shared answer")
        let transport = ArrivalTransport(answer: answer, allowsConcurrentInput: true)
        let session = ConversationSession(transport: transport)
        session.send("First question")
        await wait { session.deliveryState == .answered }
        session.send("Additional question")
        await wait { session.deliveryState == .answered }
        XCTAssertEqual(session.receivedReplies, [answer])
        XCTAssertEqual(session.messages.filter { $0.role == .assistant }, [answer])
    }

    func testFollowUpEmitsNewRepliesAndLiveUpdatesButNotOldHistory() async {
        let historical = reply("Old history")
        let first = reply("First answer")
        let updated = reply("Expanded first answer", id: first.id)
        let second = reply("Additional answer", at: first.createdAt.addingTimeInterval(1))
        let editedHistory = reply("Edited history", id: historical.id)
        let transport = ArrivalTransport(answer: first, history: [historical],
            followUp: [editedHistory, updated, second, ChatMessage(role: .user, text: "Another input")])
        let session = ConversationSession(transport: transport, followUpDelay: 0.03)
        session.resumeAutomatically()
        session.synchronizeRecentMessages()
        await wait { !session.isSynchronizing }
        session.send("Question")
        await wait { session.deliveryState == .answered && session.followUpUntil == nil }
        XCTAssertEqual(session.receivedReplies, [updated, second])
        XCTAssertTrue(session.messages.contains(editedHistory))
        session.suspend()
    }

    func testFollowUpKeepsRuntimeEventBufferBounded() async {
        let first = reply("First answer")
        let additions = (0..<40).map { reply("Additional answer \($0)",
            at: first.createdAt.addingTimeInterval(Double($0 + 1))) }
        let transport = ArrivalTransport(answer: first, followUp: additions)
        let session = ConversationSession(transport: transport, followUpDelay: 0.01)
        session.resumeAutomatically()
        session.send("Question")
        await wait { session.deliveryState == .answered && session.followUpUntil == nil }
        XCTAssertEqual(session.receivedReplies, Array(additions.suffix(32)))
        session.suspend()
    }

    func testMissingServerTimestampCannotPromoteOldHistoryUsingItsDisplayDate() async {
        let first = reply("Matched answer")
        let undated = reply("Old undated history", at: first.createdAt.addingTimeInterval(30))
        let later = reply("Dated follow-up", at: first.createdAt.addingTimeInterval(1))
        let transport = ArrivalTransport(answer: first, followUp: [undated, later], undatedIDs: [undated.id])
        let session = ConversationSession(transport: transport, followUpDelay: 0.01)
        session.resumeAutomatically()
        session.send("Question")
        await wait { session.deliveryState == .answered && session.followUpUntil == nil }
        XCTAssertEqual(session.receivedReplies, [first, later])
        XCTAssertTrue(session.messages.contains(undated))
        session.suspend()
    }

    func testSparseHistoryFollowUpExcludesOlderAndEqualTimestampReplies() async {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = reply("Matched answer", at: timestamp)
        let older = reply("Older uncached history", at: timestamp.addingTimeInterval(-60))
        let tied = reply("Ambiguous timestamp", at: timestamp)
        let later = reply("Genuine follow-up", at: timestamp.addingTimeInterval(1))
        let transport = ArrivalTransport(answer: first, followUp: [older, first, tied, later])
        let session = ConversationSession(transport: transport, followUpDelay: 0.01)
        session.resumeAutomatically()
        session.send("Question")
        await wait { session.deliveryState == .answered && session.followUpUntil == nil }
        XCTAssertEqual(session.receivedReplies, [first, later])
        XCTAssertTrue(session.messages.contains(older))
        XCTAssertTrue(session.messages.contains(tied))
        session.suspend()
    }

    func testRestoredFollowUpWithoutLiveBaselineOnlyMergesHistory() async {
        let first = reply("Saved answer")
        let unseen = reply("Uncached remote message")
        let store = ArrivalStore()
        let transport = ArrivalTransport(answer: first, followUp: [unseen])
        let original = ConversationSession(transport: transport, store: store, followUpDelay: 0.03)
        original.send("Question")
        await wait { original.deliveryState == .answered }
        original.suspend()
        let restored = ConversationSession(transport: transport, store: store)
        restored.resumeAutomatically()
        await wait { restored.followUpUntil == nil }
        XCTAssertTrue(restored.messages.contains(unseen))
        XCTAssertTrue(restored.receivedReplies.isEmpty)
        restored.suspend()
    }

    private func reply(_ text: String, id: UUID = UUID(), at date: Date = .now) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text, createdAt: date)
    }

    private func wait(until condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the conversation")
    }
}
