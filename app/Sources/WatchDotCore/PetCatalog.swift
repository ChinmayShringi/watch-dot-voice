import Foundation
import CryptoKit

public struct PetCatalogItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    let imageURL: URL?
    let expiresAt: Date?
    let updatedAt: String?

    init(id: String, name: String, imageURL: URL? = nil, expiresAt: Date? = nil, updatedAt: String? = nil) {
        self.id = id; self.name = name; self.imageURL = imageURL
        self.expiresAt = expiresAt; self.updatedAt = updatedAt
    }

    func needsURLRefresh(now: Date) -> Bool {
        imageURL == nil || (expiresAt.map { $0.timeIntervalSince(now) <= 60 } ?? false)
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$", options: .regularExpression) != nil
    }

    static func digest(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum PetCatalogError: Error, Equatable, Sendable {
    case unavailable, signedOut, identityChanged, invalidResponse, pagination, storage
    case http(Int)
    case challenge

    public var message: String {
        switch self {
        case .signedOut, .identityChanged: "Sign in again to load your avatars."
        case .storage: "Avatar storage is unavailable. Try again after unlocking your Watch."
        case .challenge: "OpenAI could not verify this connection. Try again later."
        default: "Couldn’t load avatars. Try again later."
        }
    }
}

struct PetCatalogCredentials {
    let accessToken: String
    let accountID: String
    let scope: String
}

/// The observed subscription route is private and may change independently of this app.
@MainActor
struct PetCatalogClient {
    let http: any SignInHTTP
    static let pageSize = 20
    static let maximumPages = 50
    static let maximumItems = 1_000

    func fetch(credentials: PetCatalogCredentials, validate: () throws -> Void) async throws -> [PetCatalogItem] {
        var items: [PetCatalogItem] = []
        var cursor: String?
        var cursors: Set<String> = []
        for _ in 0..<Self.maximumPages {
            try Task.checkCancellation(); try validate()
            let response = try await http.sendWithMetadata(request(credentials: credentials, cursor: cursor))
            try Task.checkCancellation(); try validate()
            guard !response.clientChallenge else { throw PetCatalogError.challenge }
            guard response.status == 200 else { throw PetCatalogError.http(response.status) }
            guard response.data.count <= 256_000 else { throw PetCatalogError.invalidResponse }
            let page: Page
            do { page = try JSONDecoder().decode(Page.self, from: response.data) }
            catch { throw PetCatalogError.invalidResponse }
            guard page.pets.count <= Self.pageSize else { throw PetCatalogError.pagination }
            let parsed = page.pets.compactMap { try? $0.entry?.item() }
            for item in parsed where !items.contains(where: { $0.id == item.id }) {
                items = items + [item]
            }
            guard items.count <= Self.maximumItems else { throw PetCatalogError.pagination }
            guard let next = page.cursor else { return items }
            guard !next.isEmpty, next.utf8.count <= 4_096, !cursors.contains(next),
                  next.rangeOfCharacter(from: .controlCharacters) == nil else { throw PetCatalogError.pagination }
            cursors = cursors.union([next]); cursor = next
        }
        throw PetCatalogError.pagination
    }

    private func request(credentials: PetCatalogCredentials, cursor: String?) -> URLRequest {
        var url = URLComponents(string: "https://chatgpt.com/backend-api/pets")!
        url.queryItems = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("watch-dot", forHTTPHeaderField: "originator")
        request.setValue("WatchDot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private struct Page: Decodable {
        let pets: [LossyEntry]
        let cursor: String?
    }

    private struct LossyEntry: Decodable {
        let entry: Entry?
        init(from decoder: any Decoder) throws { entry = try? Entry(from: decoder) }
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let spritesheet_url: String?
        let spritesheet_url_expires_at: String?
        let updated_at: String?

        func item() throws -> PetCatalogItem {
            let cleanName = name.components(separatedBy: .controlCharacters).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard PetCatalogItem.validID(id), !cleanName.isEmpty, name.utf8.count <= 1_024,
                  (updated_at?.utf8.count ?? 0) <= 128 else { throw PetCatalogError.invalidResponse }
            var url: URL?
            if let raw = spritesheet_url {
                guard raw.utf8.count <= 16_384, let candidate = URL(string: raw),
                      candidate.scheme == "https", candidate.host == "cdn.openai.com",
                      candidate.user == nil, candidate.password == nil,
                      candidate.port == nil, candidate.fragment == nil else { throw PetCatalogError.invalidResponse }
                url = candidate
            }
            var expiry: Date?
            if let raw = spritesheet_url_expires_at {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                expiry = formatter.date(from: raw)
                if expiry == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    expiry = formatter.date(from: raw)
                }
                guard expiry != nil else { throw PetCatalogError.invalidResponse }
            }
            return PetCatalogItem(id: id, name: String(cleanName.prefix(80)), imageURL: url,
                                  expiresAt: expiry, updatedAt: updated_at)
        }
    }
}
