import XCTest
@testable import WatchDotCore

@MainActor private final class PetCredentialStore: SignInStore {
    var record: SignInRecord?
    var failLoad = false
    func load() throws -> SignInRecord? {
        if failLoad { throw SignInError.storage }
        return record
    }
    func save(_ record: SignInRecord) throws { self.record = record }
}

private actor PetCredentialHTTP: SignInHTTP {
    let status: Int
    private(set) var requests = 0
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests += 1
        return (Data("{\"pets\":[],\"cursor\":null}".utf8), status)
    }
}

@MainActor final class PetCatalogConnectionTests: XCTestCase {
    private func account(subject: String = "fixture-subject", account: String = "fixture-account", revision: String = "one") throws -> SignedInAccount {
        // Synthetic already-verified vault fixture. No credentials or network are involved.
        let routing = ["chatgpt_account_id": account, "user_id": "fixture-user"]
        let claims: [String: Any] = ["sub": subject, "exp": Date().addingTimeInterval(3_600).timeIntervalSince1970,
                                     "https://api.openai.com/auth": routing, "fixture_revision": revision]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let token = "e30.\(payload).Zml4dHVyZQ"
        return SignedInAccount(subject: subject, clientID: "fixture", email: nil, expiresAt: .now.addingTimeInterval(3_600),
                               idToken: token, accessToken: token)
    }

    private func fixture(_ http: PetCredentialHTTP) throws -> (PetCredentialStore, ConnectionSession, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PetCredentialStore()
        var record = SignInRecord(); record.account = try account(); store.record = record
        return (store, ConnectionSession(store: store, http: http, chatDirectory: directory), directory)
    }

    func testTokenRotationKeepsScopeButWorkspaceChangePurges() throws {
        let (store, connection, directory) = try fixture(PetCredentialHTTP())
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try XCTUnwrap(connection.petCatalog.scope), generation = connection.petCatalog.generation
        XCTAssertEqual(scope.count, 64)
        XCTAssertFalse(scope.contains("fixture"))
        var record = try XCTUnwrap(store.record); record.account = try account(revision: "two"); store.record = record
        connection.refresh()
        XCTAssertEqual(connection.petCatalog.scope, scope)
        XCTAssertEqual(connection.petCatalog.generation, generation)
        record.account = try account(account: "another-workspace"); store.record = record
        connection.refresh()
        XCTAssertNotEqual(connection.petCatalog.scope, scope)
        XCTAssertNotEqual(connection.petCatalog.generation, generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("PetCatalog/\(scope)").path))
    }

    func testSignOutClearsScopeAndBackgroundRejectsNetwork() async throws {
        let http = PetCredentialHTTP()
        let (_, connection, directory) = try fixture(http)
        defer { try? FileManager.default.removeItem(at: directory) }
        connection.enterBackground()
        do { _ = try await connection.fetchPetCatalog(); XCTFail() }
        catch { XCTAssertEqual(error as? PetCatalogError, .signedOut) }
        let requests = await http.requests; XCTAssertEqual(requests, 0)
        connection.signOutLocally()
        XCTAssertNil(connection.petCatalog.scope)
        XCTAssertTrue(connection.petCatalog.items.isEmpty)
    }

    func testDirectCatalogRequestUsesExistingIdentityAndBounds401Retry() async throws {
        for status in [200, 401] {
            let http = PetCredentialHTTP(status: status)
            let (_, connection, directory) = try fixture(http)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let items = try await connection.fetchPetCatalog()
                XCTAssertEqual(status, 200); XCTAssertTrue(items.isEmpty)
            } catch { XCTAssertEqual(status, 401) }
            let requests = await http.requests
            XCTAssertEqual(requests, status == 200 ? 1 : 2)
        }
    }

    func testTransientKeychainFailureHidesCatalogWithoutDeletingKnownScope() async throws {
        let (store, connection, directory) = try fixture(PetCredentialHTTP())
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try XCTUnwrap(connection.petCatalog.scope)
        let marker = directory.appendingPathComponent("PetCatalog/\(scope)/private-fixture")
        try Data("synthetic cached content".utf8).write(to: marker)
        connection.petCatalog.configure { [PetCatalogItem(id: "one", name: "Fixture")] }
        await connection.petCatalog.refresh()
        XCTAssertEqual(connection.petCatalog.items.count, 1)
        store.failLoad = true; connection.refresh()
        XCTAssertNil(connection.petCatalog.scope)
        XCTAssertTrue(connection.petCatalog.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        store.failLoad = false; connection.refresh()
        XCTAssertEqual(connection.petCatalog.scope, scope)
        XCTAssertEqual(connection.petCatalog.items.count, 1)
        connection.signOutLocally()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().path))
    }
}
