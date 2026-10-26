import XCTest
@testable import WatchDotCore

private actor CatalogHTTP: SignInHTTP {
    var responses: [SignInHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [SignInHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = try await sendWithMetadata(request)
        return (result.data, result.status)
    }
    func sendWithMetadata(_ request: URLRequest) async throws -> SignInHTTPResponse {
        requests = requests + [request]
        guard let result = responses.first else { throw PetCatalogError.unavailable }
        responses = Array(responses.dropFirst())
        return result
    }
}

@MainActor final class PetCatalogTests: XCTestCase {
    private let credentials = PetCatalogCredentials(accessToken: "synthetic-token", accountID: "fixture-account", scope: "fixture-scope")

    private func page(ids: [String], cursor: String? = nil, extra: [String: Any] = [:]) throws -> SignInHTTPResponse {
        let entries = ids.map { id -> [String: Any] in
            ["id": id, "name": " \nFixture \t Avatar  ", "spritesheet_url": "https://cdn.openai.com/synthetic.webp"]
                .merging(extra) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: ["pets": entries, "cursor": cursor as Any? ?? NSNull()])
        return SignInHTTPResponse(data: data, status: 200, contentType: .json)
    }

    func testPaginationPreservesOrderAndUsesBoundAccount() async throws {
        let http = CatalogHTTP(try [page(ids: ["pet-one"], cursor: "opaque + cursor"), page(ids: ["pet-two"])])
        let items = try await PetCatalogClient(http: http).fetch(credentials: credentials) { }
        XCTAssertEqual(items.map(\.id), ["pet-one", "pet-two"])
        XCTAssertEqual(items.first?.name, "Fixture  Avatar")
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-ID"), "fixture-account")
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "cursor" })?.value, "opaque + cursor")
    }

    func testRepeatedCursorFailsAndDuplicateIDsKeepFirst() async throws {
        let repeated = try [page(ids: ["one"], cursor: "same"), page(ids: ["two"], cursor: "same")]
        do { _ = try await PetCatalogClient(http: CatalogHTTP(repeated)).fetch(credentials: credentials) { }; XCTFail() }
        catch { XCTAssertEqual(error as? PetCatalogError, .pagination) }
        let duplicates = try [page(ids: ["one"], cursor: "next"), page(ids: ["one"], extra: ["name": "Replacement"])]
        let items = try await PetCatalogClient(http: CatalogHTTP(duplicates)).fetch(credentials: credentials) { }
        XCTAssertEqual(items.map(\.id), ["one"])
        XCTAssertEqual(items.first?.name, "Fixture  Avatar")
    }

    func testUnsafeItemsAreSkippedButOversizePagesAreRejected() async throws {
        var credentialURL = URLComponents(string: "https://cdn.openai.com/x")!
        credentialURL.user = "fixture-user"
        let bad = try [page(ids: ["../private"]), page(ids: ["one"], extra: ["spritesheet_url": "https://cdn.openai.com.evil.test/x"]),
                       page(ids: ["one"], extra: ["spritesheet_url": credentialURL.url!.absoluteString]),
                       page(ids: ["one"], extra: ["name": String(repeating: "a", count: 1_025)])]
        for response in bad {
            let items = try await PetCatalogClient(http: CatalogHTTP([response])).fetch(credentials: credentials) { }
            XCTAssertTrue(items.isEmpty)
        }
        do {
            _ = try await PetCatalogClient(http: CatalogHTTP([page(ids: (0..<21).map { "pet-\($0)" })])).fetch(credentials: credentials) { }
            XCTFail()
        } catch { XCTAssertEqual(error as? PetCatalogError, .pagination) }
    }

    func testMalformedEntriesDoNotHideValidNeighborsButEnvelopeRemainsStrict() async throws {
        let entries: [Any] = [["id": "one", "name": "First"], NSNull(), 7, ["id": "bad", "name": 42],
                              ["id": "unknown", "name": "Unsupported", "spritesheet_url": "https://other.invalid/art"],
                              ["id": "two", "name": "Last"]]
        let data = try JSONSerialization.data(withJSONObject: ["pets": entries])
        let items = try await PetCatalogClient(http: CatalogHTTP([SignInHTTPResponse(data: data, status: 200)]))
            .fetch(credentials: credentials) { }
        XCTAssertEqual(items.map(\.id), ["one", "two"])
        for malformed in ["{}", "{\"pets\":null}", "{\"pets\":{}}", "{\"pets\":[],\"cursor\":42}"] {
            do {
                _ = try await PetCatalogClient(http: CatalogHTTP([SignInHTTPResponse(data: Data(malformed.utf8), status: 200)]))
                    .fetch(credentials: credentials) { }
                XCTFail()
            } catch { XCTAssertEqual(error as? PetCatalogError, .invalidResponse) }
        }
    }

    func testChallengeAndHTTPFailureNeverDecodeBodyOrRetry() async {
        for response in [SignInHTTPResponse(data: Data("private failure".utf8), status: 200, clientChallenge: true),
                         SignInHTTPResponse(data: Data("private failure".utf8), status: 401)] {
            let http = CatalogHTTP([response])
            do { _ = try await PetCatalogClient(http: http).fetch(credentials: credentials) { }; XCTFail() }
            catch { XCTAssertTrue(error is PetCatalogError) }
            let count = await http.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testIdentityIsCheckedAfterResponseBeforeParsing() async throws {
        var validations = 0
        do {
            _ = try await PetCatalogClient(http: CatalogHTTP([page(ids: ["one"])])).fetch(credentials: credentials) {
                validations += 1
                if validations == 2 { throw PetCatalogError.identityChanged }
            }
            XCTFail()
        } catch { XCTAssertEqual(error as? PetCatalogError, .identityChanged) }
    }

    func testExpirySkewAndBoundedDisplayName() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let item = PetCatalogItem(id: "one", name: "One", imageURL: URL(string: "https://cdn.openai.com/x"), expiresAt: now.addingTimeInterval(60))
        XCTAssertTrue(item.needsURLRefresh(now: now))
        XCTAssertFalse(item.needsURLRefresh(now: now.addingTimeInterval(-1)))
        let http = CatalogHTTP([try page(ids: ["one"], extra: ["name": String(repeating: "a", count: 100)])])
        let items = try await PetCatalogClient(http: http).fetch(credentials: credentials) { }
        XCTAssertEqual(items.first?.name.count, 80)
    }
}

private actor CatalogImages: PetImageDownloading {
    let payload: PetImagePayload
    var hold = false
    var calls = 0
    var statuses: [Int] = []
    var continuations: [CheckedContinuation<PetImagePayload, Error>] = []
    init() throws {
        let bytes = Data(base64Encoded: "UklGRpwAAABXRUJQVlA4TI8AAAAv/8XTAQdQwAIVuP8BAEX6/58i+p/63//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//973//+9///ve///3vf//73//+97///e9///vf//73v//97/8qAAA=")!
        payload = try PetImageDownloader.validate(data: bytes, mimeType: "image/webp")
    }
    func configure(hold: Bool = false, statuses: [Int] = []) { self.hold = hold; self.statuses = statuses }
    func download(from url: URL) async throws -> PetImagePayload {
        calls += 1
        if let status = statuses.first { statuses = Array(statuses.dropFirst()); throw PetImageDownloadError.httpStatus(status) }
        if hold { return try await withCheckedThrowingContinuation { continuations = continuations + [$0] } }
        return payload
    }
    func release() { let pending = continuations; continuations = []; for continuation in pending { continuation.resume(returning: payload) } }
}

private actor HeldCacheValidation {
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
    var calls: Int { nextID }
    func validate() async -> Bool {
        nextID += 1
        let id = nextID
        return await withCheckedContinuation { pending = pending.merging([id: $0]) { _, new in new } }
    }
    func release(_ id: Int, valid: Bool) {
        let continuation = pending[id]
        pending = pending.filter { $0.key != id }
        continuation?.resume(returning: valid)
    }
}

@MainActor final class PetCatalogSessionTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func item(_ id: String = "pet-one") -> PetCatalogItem {
        PetCatalogItem(id: id, name: "Fixture", imageURL: URL(string: "https://cdn.openai.com/synthetic.webp?private-query=fixture"))
    }

    func testOfflineRestorePersistsNoNetworkURLsAndClearsForeignScope() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }
        await session.refresh(); session.select(id: "pet-one")
        let url = await session.prepare(id: "pet-one")
        XCTAssertNotNil(url)
        let manifest = try String(contentsOf: directory.appendingPathComponent("scope-one/catalog.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("https://")); XCTAssertFalse(manifest.contains("private-query"))
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one")
        XCTAssertEqual(restored.items.map(\.id), ["pet-one"])
        XCTAssertNil(restored.cachedAsset(for: "pet-one"))
        let restoredURL = await restored.prepare(id: "pet-one")
        XCTAssertEqual(restored.cachedAsset(for: "pet-one")?.rowCount, 9)
        XCTAssertEqual(restoredURL, url)
        let calls = await images.calls; XCTAssertEqual(calls, 1)
        restored.bind(to: "scope-two")
        XCTAssertTrue(restored.items.isEmpty); XCTAssertNil(restored.cachedURL(for: "pet-one"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scope-one").path))
    }

    func testLateDownloadCannotWriteAfterSignOut() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(hold: true)
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let work = Task { await session.prepare(id: "pet-one") }
        for _ in 0..<100 { if await images.calls == 1 { break }; await Task.yield() }
        let oldGeneration = session.generation
        session.bind(to: nil)
        await images.release()
        let lateResult = await work.value
        XCTAssertNil(lateResult)
        XCTAssertNotEqual(session.generation, oldGeneration)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testImageAndCatalogRequestsAreSingleFlightAndThrottled() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(hold: true)
        let session = PetCatalogSession(directory: directory, downloader: images)
        var fetches = 0
        session.bind(to: "scope-one"); session.configure { [self] in fetches += 1; return [item()] }
        await session.refresh(); await session.refresh(); XCTAssertEqual(fetches, 1)
        let first = Task { await session.prepare(id: "pet-one") }
        let second = Task { await session.prepare(id: "pet-one") }
        for _ in 0..<100 { if await images.calls == 1 { break }; await Task.yield() }
        await images.release()
        let a = await first.value, b = await second.value
        XCTAssertNotNil(a); XCTAssertEqual(a, b)
        let calls = await images.calls; XCTAssertEqual(calls, 1)
    }

    func testMissingCDNAssetRefreshesCatalogAndRetriesOnlyOnce() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(statuses: [403, 410, 403])
        let session = PetCatalogSession(directory: directory, downloader: images)
        var fetches = 0
        session.bind(to: "scope-one"); session.configure { [self] in fetches += 1; return [item()] }
        await session.refresh()
        let result = await session.prepare(id: "pet-one")
        XCTAssertNil(result)
        let calls = await images.calls; XCTAssertEqual(calls, 2); XCTAssertEqual(fetches, 2)
        XCTAssertNotNil(session.errorMessage)
    }

    func testInitialSignedOutBindingPurgesCrashLeftovers() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old-scope")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("private fixture".utf8).write(to: old.appendingPathComponent("old"))
        let session = PetCatalogSession(directory: directory, downloader: try CatalogImages())
        session.bind(to: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testMaximumCatalogRoundTripsSelectedAvatarAboveOldManifestLimit() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        let catalog = (0..<1_000).map { index in
            PetCatalogItem(id: "pet-\(index)-" + String(repeating: "a", count: 115), name: String(repeating: "\u{1D11E}", count: 80),
                imageURL: URL(string: "https://cdn.openai.com/synthetic.webp"), updatedAt: String(repeating: "v", count: 128))
        }
        session.bind(to: "scope-one"); session.configure { catalog }; await session.refresh()
        session.select(id: catalog[0].id)
        let original = await session.prepare(id: catalog[0].id)
        XCTAssertNotNil(original)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("scope-one/catalog.json"))
        XCTAssertGreaterThan(manifest.count, 256_000)
        XCTAssertLessThan(manifest.count, PetCatalogSession.maximumManifestBytes)
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one")
        XCTAssertEqual(restored.items.count, 1_000)
        XCTAssertNil(restored.cachedURL(for: catalog[0].id))
        let restoredURL = await restored.prepare(id: catalog[0].id)
        XCTAssertEqual(restoredURL, original)
    }

    func testPreCancelledPrepareNeverStartsNetwork() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let task = Task { await session.prepare(id: "pet-one") }; task.cancel()
        let result = await task.value, calls = await images.calls
        XCTAssertNil(result); XCTAssertEqual(calls, 0)
    }

    func testSuspendThenResumeAllowsNewRequestWithoutStaleWrite() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(hold: true)
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let first = Task { await session.prepare(id: "pet-one") }
        for _ in 0..<100 { if await images.calls == 1 { break }; await Task.yield() }
        session.suspend(); await images.release()
        let cancelled = await first.value; XCTAssertNil(cancelled)
        let blocked = await session.prepare(id: "pet-one"); XCTAssertNil(blocked)
        await images.configure(); session.resume()
        let retry = await session.prepare(id: "pet-one")
        XCTAssertNotNil(retry)
        let calls = await images.calls; XCTAssertEqual(calls, 2)
    }

    func testOneCancelledWaiterDoesNotCancelOtherAndSoleCancelledWaiterCannotWrite() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(hold: true)
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item(), item("pet-two")] }; await session.refresh()
        let first = Task { await session.prepare(id: "pet-one") }
        let second = Task { await session.prepare(id: "pet-one") }
        for _ in 0..<20 { await Task.yield() }
        first.cancel(); await images.release()
        let a = await first.value, b = await second.value
        XCTAssertNil(a); XCTAssertNotNil(b)
        let only = Task { await session.prepare(id: "pet-two") }
        for _ in 0..<100 { if await images.calls == 2 { break }; await Task.yield() }
        only.cancel()
        for _ in 0..<20 { await Task.yield() }
        await images.release()
        let c = await only.value
        XCTAssertNil(c); XCTAssertNil(session.cachedURL(for: "pet-two"))
    }

    func testAtMostTwoDownloadsAndCancelledQueueDoesNotStart() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(hold: true)
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item("one"), item("two"), item("three")] }; await session.refresh()
        let first = Task { await session.prepare(id: "one") }
        let second = Task { await session.prepare(id: "two") }
        for _ in 0..<100 { if await images.calls == 2 { break }; await Task.yield() }
        let third = Task { await session.prepare(id: "three") }
        for _ in 0..<20 { await Task.yield() }
        let before = await images.calls; XCTAssertEqual(before, 2)
        third.cancel()
        let cancelled = await third.value; XCTAssertNil(cancelled)
        await images.release()
        let a = await first.value, b = await second.value
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        let after = await images.calls; XCTAssertEqual(after, 2)
    }

    func testCacheBudgetKeepsSelectedAvatarAndEvictsOldUnselectedAvatar() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let bytes = await images.payload.data.count
        let session = PetCatalogSession(directory: directory, downloader: images, maximumCacheBytes: bytes * 2)
        session.bind(to: "scope-one"); session.configure { [self] in [item("one"), item("two"), item("three")] }; await session.refresh()
        _ = await session.prepare(id: "one"); session.select(id: "one")
        _ = await session.prepare(id: "two"); _ = await session.prepare(id: "three")
        XCTAssertNotNil(session.cachedURL(for: "one")); XCTAssertNil(session.cachedURL(for: "two"))
        XCTAssertNotNil(session.cachedURL(for: "three"))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("scope-one").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".atlas") }.count, 2)
    }

    func testCorruptCachedImageIsRejectedAndRemovedOnRestore() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let prepared = await session.prepare(id: "pet-one")
        let url = try XCTUnwrap(prepared)
        try Data("invalid fixture".utf8).write(to: url)
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one")
        XCTAssertNil(restored.cachedURL(for: "pet-one"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExpiredURLRefreshesBeforeAnyImageDownload() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        var fetches = 0
        session.bind(to: "scope-one"); session.configure { [self] in
            fetches += 1
            return fetches == 1 ? [PetCatalogItem(id: "pet-one", name: "Fixture", imageURL: item().imageURL,
                                                expiresAt: .distantPast)] : [item()]
        }
        await session.refresh()
        let url = await session.prepare(id: "pet-one")
        XCTAssertNotNil(url); XCTAssertEqual(fetches, 2)
        let calls = await images.calls; XCTAssertEqual(calls, 1)
    }

    func testAutomaticRefreshFailureBackoffAndExplicitRetry() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 1_000), fetches = 0
        let session = PetCatalogSession(directory: directory, downloader: try CatalogImages(), now: { clock })
        session.bind(to: "scope-one"); session.configure { fetches += 1; throw PetCatalogError.unavailable }
        await session.refresh(); await session.refresh()
        _ = await session.prepare(id: "pet-one")
        XCTAssertEqual(fetches, 1)
        clock = clock.addingTimeInterval(31)
        await session.refresh(); XCTAssertEqual(fetches, 2)
        await session.refresh(retry: true); XCTAssertEqual(fetches, 3)
    }

    func testNewImageAttemptClearsOldErrorAndSuccessLeavesNoError() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages(); await images.configure(statuses: [500])
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        _ = await session.prepare(id: "pet-one"); XCTAssertNotNil(session.errorMessage)
        await images.configure(hold: true)
        let retry = Task { await session.prepare(id: "pet-one") }
        for _ in 0..<100 { if await images.calls == 2 { break }; await Task.yield() }
        XCTAssertNil(session.errorMessage)
        await images.release()
        let url = await retry.value
        XCTAssertNotNil(url); XCTAssertNil(session.errorMessage)
    }

    func testSelectedCachedAvatarWarmsWithoutNetworkAndNeverPublishesUnverifiedURL() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        _ = await session.prepare(id: "pet-one"); session.select(id: "pet-one")
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one")
        XCTAssertNil(restored.cachedURL(for: "pet-one"))
        for _ in 0..<1_000 {
            if restored.cachedURL(for: "pet-one") != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(restored.cachedURL(for: "pet-one"))
        let calls = await images.calls; XCTAssertEqual(calls, 1)
    }

    func testSameLengthCorruptAssetDoesNotEscapeDeferredIntegrityValidation() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let prepared = await session.prepare(id: "pet-one")
        let url = try XCTUnwrap(prepared)
        session.select(id: "pet-one")
        let bytes = try Data(contentsOf: url)
        try Data(repeating: 0, count: bytes.count).write(to: url)
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one")
        XCTAssertNil(restored.cachedURL(for: "pet-one"))
        for _ in 0..<1_000 {
            if !FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(restored.cachedURL(for: "pet-one"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let calls = await images.calls; XCTAssertEqual(calls, 1)
    }
    func testDelayedInvalidWarmResultCannotDeleteRepairedSameFilename() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let original = PetCatalogSession(directory: directory, downloader: images)
        original.bind(to: "scope-one"); original.configure { [self] in [item()] }; await original.refresh()
        let saved = await original.prepare(id: "pet-one")
        let url = try XCTUnwrap(saved)
        original.select(id: "pet-one")
        let bytes = try Data(contentsOf: url)
        try Data(repeating: 0, count: bytes.count).write(to: url)
        let validation = HeldCacheValidation()
        let restored = PetCatalogSession(directory: directory, downloader: images,
            cacheValidator: { _ in await validation.validate() })
        restored.bind(to: "scope-one"); restored.configure { [self] in [item()] }
        for _ in 0..<1_000 { if await validation.calls == 1 { break }; await Task.yield() }
        let requested = Task { await restored.prepare(id: "pet-one") }
        for _ in 0..<1_000 { if await validation.calls == 2 { break }; await Task.yield() }
        let calls = await validation.calls; XCTAssertEqual(calls, 2)
        await validation.release(2, valid: false)
        let repaired = await requested.value
        XCTAssertEqual(repaired, url)
        await validation.release(1, valid: false)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(restored.cachedURL(for: "pet-one"), url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(restored.errorMessage)
    }

    func testDelayedSuccessfulWarmResultDoesNotPublishEvictedFile() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let original = PetCatalogSession(directory: directory, downloader: images)
        original.bind(to: "scope-one"); original.configure { [self] in [item(), item("pet-two")] }
        await original.refresh()
        let saved = await original.prepare(id: "pet-one")
        let url = try XCTUnwrap(saved), byteCount = try Data(contentsOf: url).count
        original.select(id: "pet-one")
        let validation = HeldCacheValidation()
        let restored = PetCatalogSession(directory: directory, downloader: images, maximumCacheBytes: byteCount,
            cacheValidator: { _ in await validation.validate() })
        restored.bind(to: "scope-one"); restored.configure { [self] in [item(), item("pet-two")] }
        for _ in 0..<1_000 { if await validation.calls == 1 { break }; await Task.yield() }
        restored.select(id: nil)
        let next = await restored.prepare(id: "pet-two")
        XCTAssertNotNil(next); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let revision = restored.cacheRevision
        await validation.release(1, valid: true)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertNil(restored.cachedURL(for: "pet-one"))
        XCTAssertEqual(restored.cacheRevision, revision)
        XCTAssertNil(restored.errorMessage)
    }

    func testFileRemovedAfterMetadataLoadIsRecoveredAsCacheMiss() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let original = PetCatalogSession(directory: directory, downloader: images)
        original.bind(to: "scope-one"); original.configure { [self] in [item()] }; await original.refresh()
        let saved = await original.prepare(id: "pet-one")
        let url = try XCTUnwrap(saved)
        let restored = PetCatalogSession(directory: directory, downloader: images)
        restored.bind(to: "scope-one"); restored.configure { [self] in [item()] }
        try FileManager.default.removeItem(at: url)
        let repaired = await restored.prepare(id: "pet-one")
        XCTAssertNotNil(repaired); XCTAssertNil(restored.errorMessage)
        let calls = await images.calls; XCTAssertEqual(calls, 2)
    }

    func testValidatedFileDisappearingInSameSessionIsDownloadedAgain() async throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let images = try CatalogImages()
        let session = PetCatalogSession(directory: directory, downloader: images)
        session.bind(to: "scope-one"); session.configure { [self] in [item()] }; await session.refresh()
        let saved = await session.prepare(id: "pet-one")
        let url = try XCTUnwrap(saved)
        XCTAssertEqual(session.cachedURL(for: "pet-one"), url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(session.cachedURL(for: "pet-one"))
        let repaired = await session.prepare(id: "pet-one")
        XCTAssertEqual(repaired, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(session.errorMessage)
        let calls = await images.calls; XCTAssertEqual(calls, 2)
    }

}
