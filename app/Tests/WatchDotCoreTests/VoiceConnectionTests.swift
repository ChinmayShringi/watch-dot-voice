import XCTest
@testable import WatchDotCore

@MainActor private final class VoiceAccountStore: SignInStore {
    var record: SignInRecord?
    init(_ account: SignedInAccount) {
        var initial = SignInRecord()
        initial.account = account
        record = initial
    }
    func load() throws -> SignInRecord? { record }
    func save(_ record: SignInRecord) throws { self.record = record }
}

private actor VoiceConnectionHTTP: SignInHTTP {
    let signer: SigningFixture
    init() throws { signer = try SigningFixture() }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        if path == "/.well-known/jwks.json" { return (signer.jwks, 200) }
        if path == "/oauth/token" {
            let routing = ["chatgpt_account_id": "account-fixture", "user_id": "user-fixture"]
            let access = try JSONSerialization.data(withJSONObject: [
                "exp": voiceFixtureNow.addingTimeInterval(7200).timeIntervalSince1970,
                "https://api.openai.com/auth": routing
            ]).base64URL
            let identity = try signer.token(nonce: "voice-nonce", client: OpenAIOAuthClient.codex, changes: [
                "sub": "voice-subject", "iat": voiceFixtureNow.addingTimeInterval(-10).timeIntervalSince1970,
                "exp": voiceFixtureNow.addingTimeInterval(7200).timeIntervalSince1970,
                "https://api.openai.com/auth": routing
            ])
            return (try JSONSerialization.data(withJSONObject: ["access_token": "fixture.\(access).fixture",
                "id_token": identity, "refresh_token": "rotated-fixture", "expires_in": 7200]), 200)
        }
        if path.hasSuffix("/tbo/primary") {
            return (Data(#"{"selection":{"available":true,"aeon_id":"dot-fixture","messaging_room_id":"room-fixture"}}"#.utf8), 200)
        }
        if path.hasSuffix("/rooms/room-fixture") {
            return (Data(#"{"id":"room-fixture","type":"DM","app_source":"chatgpt:messaging","aeon_id":"dot-fixture","members":[{"account_user_id":"user-fixture"},{"account_user_id":"dot-user-fixture","aeon_id":"dot-fixture"}]}"#.utf8), 200)
        }
        return (Data(#"{"items":[]}"#.utf8), 200)
    }
}

@MainActor final class VoiceConnectionTests: XCTestCase {
    private func connected(upload: TranscriptionHTTPStub = TranscriptionHTTPStub(), renewable: Bool = false)
    async throws -> (ConnectionSession, VoiceAccountStore, URL) {
        let account = try voiceFixtureAccount()
        let initial = SignedInAccount(subject: account.subject, clientID: account.clientID, email: nil,
            expiresAt: account.expiresAt, idToken: account.idToken, accessToken: account.accessToken,
            refreshToken: renewable ? "refresh-fixture" : nil, authorizationNonce: "voice-nonce")
        let store = VoiceAccountStore(initial)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let connection = ConnectionSession(store: store, http: try VoiceConnectionHTTP(), now: { voiceFixtureNow },
                                           chatDirectory: directory, transcriptionHTTP: upload)
        connection.probeDotAccess()
        for _ in 0..<100 {
            if connection.directConversation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertNotNil(connection.directConversation)
        return (connection, store, directory)
    }

    func testVoiceSendPreservesUnrelatedTextDraft() async throws {
        let (connection, _, directory) = try await connected()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = try XCTUnwrap(connection.directConversation)
        conversation.draft = "Unfinished typed message"
        let turn = try connection.makeVoiceTurn()
        XCTAssertTrue(turn.send("A separate voice message"))
        XCTAssertEqual(conversation.draft, "Unfinished typed message")
        XCTAssertEqual(conversation.messages.last?.text, "A separate voice message")
        connection.signOutLocally()
    }

    func testForegroundAndDemoAreCheckedBeforeCaptureAndAtSend() async throws {
        let (connection, _, directory) = try await connected()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = try connection.makeVoiceTurn()
        connection.enterBackground()
        XCTAssertThrowsError(try connection.makeVoiceTurn())
        XCTAssertFalse(turn.send("must not send"))
        connection.enterForeground()
        XCTAssertFalse(turn.send("still stale after foreground"))
        connection.selectDemo(true)
        XCTAssertThrowsError(try connection.makeVoiceTurn())
        connection.selectDemo(false)
        XCTAssertFalse(turn.send("still stale after demo"))
        connection.signOutLocally()
    }

    func testSignOutDuringNonCooperativeUploadRejectsTranscript() async throws {
        let upload = TranscriptionHTTPStub(hold: true)
        let (connection, _, directory) = try await connected(upload: upload)
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = try connection.makeVoiceTurn()
        let task = Task { try await turn.transcribe(voiceFixtureClip) }
        for _ in 0..<100 {
            if await upload.waiting() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        connection.signOutLocally()
        await upload.release()
        do { _ = try await task.value; XCTFail("Must reject changed session") }
        catch { XCTAssertEqual(error as? VoiceInputIssue, .sessionChanged) }
        XCTAssertFalse(turn.send("stale"))
    }

    func testPersistedAccountChangeFailsBeforeUploadWithoutRefresh() async throws {
        let upload = TranscriptionHTTPStub()
        let (connection, store, directory) = try await connected(upload: upload)
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = try connection.makeVoiceTurn()
        store.record = nil
        do { _ = try await turn.transcribe(voiceFixtureClip); XCTFail("Account removed") }
        catch { XCTAssertEqual(error as? VoiceInputIssue, .sessionChanged) }
        let requests = await upload.captured()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(turn.send("stale"))
        connection.signOutLocally()
    }

    func testRoomResetInvalidatesCapturedTurnEvenWhenSameRoomReopens() async throws {
        let (connection, _, directory) = try await connected()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = try connection.makeVoiceTurn()
        let original = connection.directConversation
        connection.probeDotAccess()
        for _ in 0..<100 {
            if connection.directConversation != nil { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(connection.directConversation === original)
        XCTAssertFalse(turn.send("stale room binding"))
        connection.signOutLocally()
    }

    func testTokenRenewalPreservesBindingAndUsesRenewedCredential() async throws {
        let upload = TranscriptionHTTPStub()
        let (connection, _, directory) = try await connected(upload: upload, renewable: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = try connection.makeVoiceTurn()
        let generation = connection.voiceGeneration
        let renewed = try await connection.ensureCurrentAccount(force: true)
        XCTAssertEqual(connection.voiceGeneration, generation)
        let text = try await turn.transcribe(voiceFixtureClip)
        XCTAssertEqual(text, "hello")
        let requests = await upload.captured()
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(renewed.accessToken!)")
        XCTAssertTrue(turn.send(text))
        XCTAssertFalse(turn.send(text))
        XCTAssertEqual(connection.directConversation?.messages.filter { $0.role == .user }.count, 1)
        connection.signOutLocally()
    }
}
