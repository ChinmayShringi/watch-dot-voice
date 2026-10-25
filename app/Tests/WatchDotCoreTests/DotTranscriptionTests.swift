import XCTest
@testable import WatchDotCore

let voiceFixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
func voiceFixtureAccount(accountID: String = "account-fixture", userID: String = "user-fixture") throws -> SignedInAccount {
    let routing = ["chatgpt_account_id": accountID, "user_id": userID]
    func token(_ claims: [String: Any]) throws -> String {
        "fixture.\(try JSONSerialization.data(withJSONObject: claims).base64URL).fixture"
    }
    return SignedInAccount(subject: "voice-subject", clientID: OpenAIOAuthClient.codex, email: nil,
        expiresAt: voiceFixtureNow.addingTimeInterval(3600),
        idToken: try token(["sub": "voice-subject", "https://api.openai.com/auth": routing]),
        accessToken: try token(["exp": voiceFixtureNow.addingTimeInterval(3600).timeIntervalSince1970,
                               "https://api.openai.com/auth": routing]))
}
let voiceFixtureDestination = LocatedDot(name: "fixture", dotID: "dot-fixture", roomID: "room-fixture",
    accountID: "account-fixture", userID: "user-fixture", dotMemberID: "dot-user-fixture")
let voiceFixtureClip = VoiceClip(data: Data("m4a-fixture".utf8), duration: 2, hasSpeech: true)

actor TranscriptionHTTPStub: SignInHTTP {
    let response: SignInHTTPResponse
    let hold: Bool
    let networkFailure: Bool
    var requests: [URLRequest] = []
    var continuation: CheckedContinuation<Void, Never>?
    init(data: Data = Data(#"{"text":" hello "}"#.utf8), status: Int = 200,
         challenge: Bool = false, hold: Bool = false, networkFailure: Bool = false) {
        response = SignInHTTPResponse(data: data, status: status, contentType: .json, clientChallenge: challenge)
        self.hold = hold; self.networkFailure = networkFailure
    }
    func captured() -> [URLRequest] { requests }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await sendWithMetadata(request)
        return (result.data, result.status)
    }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        requests = requests + [request]
        if hold { await withCheckedContinuation { continuation = $0 } }
        if networkFailure { throw URLError(.timedOut) }
        return response
    }
}

@MainActor final class DotTranscriptionTests: XCTestCase {
    func testMultipartUsesFixedEndpointExistingIdentityEnglishAndM4A() async throws {
        let http = TranscriptionHTTPStub()
        let account = try voiceFixtureAccount()
        let text = try await DotTranscription(http: http).transcribe(voiceFixtureClip, account: account,
            destination: voiceFixtureDestination, now: voiceFixtureNow)
        XCTAssertEqual(text, "hello")
        let requests = await http.captured()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(account.accessToken!)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "watch-dot")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WatchDot/1.0")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4"))
        XCTAssertTrue(body.contains("m4a-fixture"))
        let boundary = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
    }

    func testRejectionsAndMalformedResponsesNeverRetryOrLeakBody() async throws {
        let cases: [(Data, Int, Bool, VoiceInputIssue)] = [
            (Data("secret-body".utf8), 401, false, .sessionChanged),
            (Data("secret-body".utf8), 403, false, .transcriptionHTTP(403)),
            (Data("secret-body".utf8), 429, false, .transcriptionHTTP(429)),
            (Data("secret-body".utf8), 302, false, .transcriptionHTTP(302)),
            (Data("secret-body".utf8), 200, true, .challenge),
            (Data("secret-body".utf8), 200, false, .malformedResponse),
            (Data(repeating: 32, count: 256_001), 200, false, .malformedResponse),
            (Data(#"{"text":" \n "}"#.utf8), 200, false, .noSpeech),
            (try JSONEncoder().encode(["text": String(repeating: "a", count: 8001)]), 200, false, .transcriptTooLong)
        ]
        for (body, status, challenge, expected) in cases {
            let http = TranscriptionHTTPStub(data: body, status: status, challenge: challenge)
            do {
                _ = try await DotTranscription(http: http).transcribe(voiceFixtureClip, account: voiceFixtureAccount(),
                    destination: voiceFixtureDestination, now: voiceFixtureNow)
                XCTFail("Must reject response")
            } catch { XCTAssertEqual(error as? VoiceInputIssue, expected) }
            let requests = await http.captured()
            XCTAssertEqual(requests.count, 1)
            XCTAssertFalse(expected.message.contains("secret-body"))
        }
    }

    func testInvalidClipsAndChangedRoutingNeverUpload() async throws {
        let http = TranscriptionHTTPStub()
        let clips = [VoiceClip(data: Data(), duration: 1, hasSpeech: true),
                     VoiceClip(data: Data([1]), duration: .nan, hasSpeech: true),
                     VoiceClip(data: Data([1]), duration: 61, hasSpeech: true),
                     VoiceClip(data: Data(repeating: 1, count: 2_000_001), duration: 60, hasSpeech: true),
                     VoiceClip(data: Data([1]), duration: 1, hasSpeech: false)]
        for clip in clips {
            do {
                _ = try await DotTranscription(http: http).transcribe(clip, account: voiceFixtureAccount(),
                    destination: voiceFixtureDestination, now: voiceFixtureNow)
                XCTFail("Invalid recording")
            } catch {}
        }
        do {
            _ = try await DotTranscription(http: http).transcribe(voiceFixtureClip,
                account: voiceFixtureAccount(accountID: "different-account"),
                destination: voiceFixtureDestination, now: voiceFixtureNow)
            XCTFail("Different routing")
        } catch { XCTAssertEqual(error as? VoiceInputIssue, .sessionChanged) }
        let requests = await http.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationRejectsNonCooperativeHTTPCompletion() async throws {
        let http = TranscriptionHTTPStub(hold: true)
        let account = try voiceFixtureAccount()
        let task = Task {
            try await DotTranscription(http: http).transcribe(voiceFixtureClip, account: account,
                destination: voiceFixtureDestination, now: voiceFixtureNow)
        }
        for _ in 0..<100 {
            if await http.waiting() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel(); await http.release()
        do { _ = try await task.value; XCTFail("Cancelled upload") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testNetworkTimeoutIsSafeAndDoesNotRetry() async throws {
        let http = TranscriptionHTTPStub(networkFailure: true)
        do {
            _ = try await DotTranscription(http: http).transcribe(voiceFixtureClip, account: voiceFixtureAccount(),
                destination: voiceFixtureDestination, now: voiceFixtureNow)
            XCTFail("Network error")
        } catch { XCTAssertEqual(error as? VoiceInputIssue, .unavailable) }
        let requests = await http.captured(); XCTAssertEqual(requests.count, 1)
    }
}
