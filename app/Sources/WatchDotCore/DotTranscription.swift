import Foundation

struct DotTranscription: Sendable {
    private let http: any SignInHTTP
    init(http: any SignInHTTP = SecureSignInHTTP(requestTimeout: 60, resourceTimeout: 60)) {
        self.http = http
    }

    func transcribe(_ clip: VoiceClip, account: SignedInAccount, destination: LocatedDot,
                    now: Date) async throws -> String {
        try Task.checkCancellation()
        try clip.validate()
        guard account.clientID == OpenAIOAuthClient.codex, account.expiresAt > now,
              let token = account.accessToken else { throw VoiceInputIssue.sessionChanged }
        do {
            let identity = try DotAccessProbe(http: http).routingIdentity(token, account: account, now: now)
            guard identity.accountID == destination.accountID, identity.userID == destination.userID else {
                throw VoiceInputIssue.sessionChanged
            }
        } catch { throw VoiceInputIssue.sessionChanged }
        let response: SignInHTTPResponse
        do { response = try await http.sendWithMetadata(makeRequest(clip, token: token, accountID: destination.accountID)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VoiceInputIssue.unavailable }
        try Task.checkCancellation()
        guard !response.clientChallenge else { throw VoiceInputIssue.challenge }
        guard response.status == 200 else {
            if response.status == 401 { throw VoiceInputIssue.sessionChanged }
            throw VoiceInputIssue.transcriptionHTTP(response.status)
        }
        guard response.data.count <= 256_000,
              response.contentType == .json || response.contentType == .unknown,
              let value = try? JSONDecoder().decode(Transcript.self, from: response.data) else {
            throw VoiceInputIssue.malformedResponse
        }
        return try Self.validatedText(value.text)
    }

    static func validatedText(_ text: String) throws -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw VoiceInputIssue.noSpeech }
        guard cleaned.utf8.count <= 8_000 else { throw VoiceInputIssue.transcriptTooLong }
        return cleaned
    }

    private func makeRequest(_ clip: VoiceClip, token: String, accountID: String) -> URLRequest {
        let boundary = "WatchDot-\(UUID().uuidString)"
        let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nen\r\n" +
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\n" +
            "Content-Type: audio/mp4\r\n\r\n"
        let body = Data(prefix.utf8) + clip.data + Data("\r\n--\(boundary)--\r\n".utf8)
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("watch-dot", forHTTPHeaderField: "originator")
        request.setValue("WatchDot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private struct Transcript: Decodable { let text: String }
}
