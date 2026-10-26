import Foundation
import Combine
import CryptoKit

public struct PetCachedAsset: Equatable, Sendable {
    public let url: URL
    public let rowCount: Int
}

@MainActor
public final class PetCatalogSession: ObservableObject {
    @Published public private(set) var items: [PetCatalogItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var generation = UUID()
    @Published public private(set) var cacheRevision = UUID()
    public private(set) var scope: String?

    private let directory: URL
    private let downloader: any PetImageDownloading
    private let now: () -> Date
    private let maximumCacheBytes: Int
    private let cacheValidator: CacheValidator
    private var fetch: (() async throws -> [PetCatalogItem])?
    private var catalogTask: Task<Void, Never>?
    private var imageTasks: [String: ImageRequest] = [:]
    private var activeDownloads: Set<UUID> = []
    private var waitingDownloads: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var operation = UUID()
    private var assets: [StoredAsset] = []
    private var selectedID: String?
    private var lastRefresh: Date?
    private var refreshRetryAfter: Date?
    private var validatedFiles: Set<String> = []
    private var warmTask: Task<Void, Never>?
    private var hasBound = false
    private var isSuspended = false
    static let maximumManifestBytes = 2_097_152

    public convenience init(directory: URL, downloader: any PetImageDownloading = PetImageDownloader(),
                maximumCacheBytes: Int = 32 * 1024 * 1024, now: @escaping () -> Date = Date.init) {
        self.init(directory: directory, downloader: downloader, maximumCacheBytes: maximumCacheBytes,
                  now: now, cacheValidator: Self.validateCacheFile)
    }

    init(directory: URL, downloader: any PetImageDownloading,
         maximumCacheBytes: Int = 32 * 1024 * 1024, now: @escaping () -> Date = Date.init,
         cacheValidator: @escaping CacheValidator) {
        self.directory = directory; self.downloader = downloader
        self.cacheValidator = cacheValidator
        self.maximumCacheBytes = maximumCacheBytes; self.now = now
    }

    func configure(fetch: @escaping () async throws -> [PetCatalogItem]) { self.fetch = fetch }

    /// Identity changes synchronously clear observable content and cancel every pending write.
    func bind(to newScope: String?) {
        guard !hasBound || scope != newScope else { return }
        hasBound = true
        suspend()
        scope = newScope; items = []; assets = []; validatedFiles = []
        selectedID = nil; lastRefresh = nil; refreshRetryAfter = nil; errorMessage = nil; cacheRevision = UUID()
        generation = UUID()
        isSuspended = false
        do {
            try protectDirectory(directory)
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if child.lastPathComponent != newScope { try FileManager.default.removeItem(at: child) }
            }
            if let newScope { try load(scope: newScope) }
            warmSelectedAsset()
        } catch { errorMessage = PetCatalogError.storage.message }
    }

    /// Protected credentials may be temporarily unreadable while the device is locked.
    func hideForUnavailableIdentity() {
        suspend()
        scope = nil; items = []; assets = []; validatedFiles = []; selectedID = nil
        hasBound = false; cacheRevision = UUID(); generation = UUID()
        errorMessage = PetCatalogError.storage.message
    }

    public func suspend() {
        isSuspended = true
        operation = UUID()
        catalogTask?.cancel(); catalogTask = nil
        warmTask?.cancel(); warmTask = nil
        for request in imageTasks.values { request.task.cancel() }
        imageTasks = [:]; isLoading = false
    }

    public func resume() { isSuspended = false; warmSelectedAsset() }

    public func refresh(retry: Bool = false) async { await refresh(force: retry, bypassBackoff: retry) }

    private func refresh(force: Bool, bypassBackoff: Bool = false) async {
        if let task = catalogTask { await task.value; return }
        guard !Task.isCancelled, !isSuspended, scope != nil, let fetch else { return }
        if !bypassBackoff, let refreshRetryAfter, now() < refreshRetryAfter { return }
        if !force, let lastRefresh, now().timeIntervalSince(lastRefresh) < 180 { return }
        let expected = generation, currentOperation = operation
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == currentOperation { self.isLoading = false; self.catalogTask = nil } }
            do {
                let result = try await fetch()
                try self.check(expected, currentOperation)
                self.items = result; self.lastRefresh = self.now(); self.refreshRetryAfter = nil; self.errorMessage = nil
                try self.persist()
            } catch is CancellationError { }
            catch {
                guard self.generation == expected, self.operation == currentOperation else { return }
                self.refreshRetryAfter = self.now().addingTimeInterval(30)
                self.errorMessage = (error as? PetCatalogError)?.message ?? PetCatalogError.unavailable.message
            }
        }
        catalogTask = task
        await task.value
    }

    public func cachedAsset(for id: String) -> PetCachedAsset? {
        guard let scope, let asset = assets.first(where: { $0.id == id }), validatedFiles.contains(asset.filename),
              FileManager.default.fileExists(atPath: fileURL(asset, scope: scope).path) else { return nil }
        return PetCachedAsset(url: fileURL(asset, scope: scope), rowCount: asset.rowCount)
    }

    public func cachedURL(for id: String) -> URL? { cachedAsset(for: id)?.url }

    public func select(id: String?) {
        guard id == nil || PetCatalogItem.validID(id!) else { return }
        selectedID = id
        assets = assets.map { $0.id == id ? $0.accessed(at: now()) : $0 }
        do { try persist() } catch { errorMessage = PetCatalogError.storage.message }
    }

    public func prepare(id: String) async -> URL? {
        guard !Task.isCancelled, !isSuspended, PetCatalogItem.validID(id), scope != nil else { return nil }
        if let cached = cachedURL(for: id), let asset = assets.first(where: { $0.id == id }),
           !items.contains(where: { $0.id == id && $0.updatedAt != asset.updatedAt }) {
            assets = assets.map { $0.id == id ? $0.accessed(at: now()) : $0 }
            return cached
        }
        let waiter = UUID()
        if let request = imageTasks[id] {
            imageTasks = imageTasks.merging([id: request.adding(waiter)]) { _, new in new }
            return await wait(for: request, petID: id, waiter: waiter)
        }
        let expected = generation, currentOperation = operation
        errorMessage = nil
        let requestID = UUID()
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            defer {
                self.releaseDownload(requestID)
                if self.imageTasks[id]?.id == requestID {
                    self.imageTasks = self.imageTasks.filter { $0.key != id }
                }
            }
            do {
                try await self.acquireDownload(requestID)
                return try await self.prepareImage(id: id, generation: expected, operation: currentOperation)
            } catch is CancellationError { return nil }
            catch {
                guard self.generation == expected, self.operation == currentOperation else { return nil }
                self.errorMessage = (error as? PetCatalogError)?.message ?? "Couldn’t download this avatar. Try again later."
                return self.cachedURL(for: id)
            }
        }
        let request = ImageRequest(id: requestID, task: task, waiters: [waiter])
        imageTasks = imageTasks.merging([id: request]) { _, new in new }
        return await wait(for: request, petID: id, waiter: waiter)
    }

    private func wait(for request: ImageRequest, petID: String, waiter: UUID) async -> URL? {
        await withTaskCancellationHandler {
            let result = await request.task.value
            removeWaiter(waiter, petID: petID, requestID: request.id)
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(waiter, petID: petID, requestID: request.id) }
        }
    }

    private func removeWaiter(_ waiter: UUID, petID: String, requestID: UUID) {
        guard let request = imageTasks[petID], request.id == requestID else { return }
        let remaining = request.waiters.subtracting([waiter])
        if remaining.isEmpty {
            request.task.cancel()
            imageTasks = imageTasks.filter { $0.key != petID }
        } else {
            imageTasks = imageTasks.merging([petID: ImageRequest(id: request.id, task: request.task, waiters: remaining)]) { _, new in new }
        }
    }

    private func acquireDownload(_ id: UUID) async throws {
        try Task.checkCancellation()
        if activeDownloads.count < 2 { activeDownloads = activeDownloads.union([id]); return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitingDownloads = waitingDownloads + [(id, continuation)]
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaitingDownload(id) }
        }
        try Task.checkCancellation()
    }

    private func cancelWaitingDownload(_ id: UUID) {
        guard let waiting = waitingDownloads.first(where: { $0.0 == id }) else { return }
        waitingDownloads = waitingDownloads.filter { $0.0 != id }
        waiting.1.resume(throwing: CancellationError())
    }

    private func releaseDownload(_ id: UUID) {
        guard activeDownloads.contains(id) else { return }
        activeDownloads = activeDownloads.subtracting([id])
        if let next = waitingDownloads.first {
            waitingDownloads = Array(waitingDownloads.dropFirst())
            activeDownloads = activeDownloads.union([next.0])
            next.1.resume()
        }
    }

    private func prepareImage(id: String, generation: UUID, operation: UUID) async throws -> URL {
        if let asset = assets.first(where: { $0.id == id }),
           !items.contains(where: { $0.id == id && $0.updatedAt != asset.updatedAt }),
           let cached = try await validateCachedAsset(asset, generation: generation, operation: operation) {
            errorMessage = nil
            return cached
        }
        if items.first(where: { $0.id == id })?.needsURLRefresh(now: now()) != false {
            await refresh(force: true)
            try check(generation, operation)
        }
        for attempt in 0...1 {
            try check(generation, operation)
            guard let item = items.first(where: { $0.id == id }), !item.needsURLRefresh(now: now()),
                  let url = item.imageURL else { throw PetCatalogError.unavailable }
            do {
                let payload = try await downloader.download(from: url)
                let hashing = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return SHA256.hash(data: payload.data).map { String(format: "%02x", $0) }.joined()
                }
                let digest = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
                try check(generation, operation)
                let saved = try save(payload, item: item, contentHash: digest)
                return saved
            } catch PetImageDownloadError.httpStatus(let status) where attempt == 0 && [403, 404, 410].contains(status) {
                await refresh(force: true, bypassBackoff: true)
                try check(generation, operation)
            }
        }
        throw PetCatalogError.unavailable
    }

    private func check(_ expected: UUID, _ currentOperation: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected, operation == currentOperation, scope != nil else {
            throw PetCatalogError.identityChanged
        }
    }

    private func save(_ payload: PetImagePayload, item: PetCatalogItem, contentHash: String) throws -> URL {
        guard let scope else { throw PetCatalogError.identityChanged }
        guard payload.width == 1_536, [1_872, 2_288].contains(payload.height),
              payload.data.count <= PetImageDownloader.maximumBytes else { throw PetCatalogError.storage }
        let filename = PetCatalogItem.digest([scope, item.id, item.updatedAt ?? "", contentHash]) + ".atlas"
        let asset = StoredAsset(id: item.id, filename: filename, format: payload.format,
            rowCount: payload.rowCount, byteCount: payload.data.count, updatedAt: item.updatedAt,
            contentHash: contentHash, accessedAt: now())
        let url = fileURL(asset, scope: scope)
        try protectDirectory(url.deletingLastPathComponent())
        try write(payload.data, to: url)
        assets = assets.filter { $0.id != item.id } + [asset]
        try evict(preserving: item.id)
        try persist()
        validatedFiles = validatedFiles.union([asset.filename])
        errorMessage = nil
        cacheRevision = UUID()
        return url
    }

    private func warmSelectedAsset() {
        guard !isSuspended, warmTask == nil, let selectedID,
              let asset = assets.first(where: { $0.id == selectedID }),
              !validatedFiles.contains(asset.filename) else { return }
        let expected = generation, currentOperation = operation
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == currentOperation { self.warmTask = nil } }
            do { _ = try await self.validateCachedAsset(asset, generation: expected, operation: currentOperation) }
            catch is CancellationError { }
            catch {
                if self.generation == expected, self.operation == currentOperation {
                    self.errorMessage = PetCatalogError.storage.message
                }
            }
        }
    }

    private func validateCachedAsset(_ asset: StoredAsset, generation: UUID, operation: UUID) async throws -> URL? {
        try check(generation, operation)
        guard let scope else { throw PetCatalogError.identityChanged }
        let url = fileURL(asset, scope: scope)
        if validatedFiles.contains(asset.filename) {
            if let cached = cachedURL(for: asset.id) { return cached }
            validatedFiles = validatedFiles.subtracting([asset.filename])
            return nil
        }
        let request = CacheValidationRequest(url: url, byteCount: asset.byteCount,
            contentHash: asset.contentHash, format: asset.format, rowCount: asset.rowCount)
        let validate = cacheValidator
        let validation = Task.detached(priority: .utility) { try await validate(request) }
        let valid = try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
        try check(generation, operation)
        guard assets.contains(where: { $0.id == asset.id && $0.filename == asset.filename }),
              !validatedFiles.contains(asset.filename) else { return cachedURL(for: asset.id) }
        guard valid else {
            assets = assets.filter { $0.filename != asset.filename }
            do { try FileManager.default.removeItem(at: url) }
            catch where Self.isMissingFile(error) { }
            try persist()
            return nil
        }
        validatedFiles = validatedFiles.union([asset.filename]); cacheRevision = UUID()
        return url
    }

    struct CacheValidationRequest: Sendable {
        let url: URL
        let byteCount: Int
        let contentHash: String
        let format: PetImageFormat
        let rowCount: Int
    }
    typealias CacheValidator = @Sendable (CacheValidationRequest) async throws -> Bool

    nonisolated private static func validateCacheFile(_ request: CacheValidationRequest) async throws -> Bool {
        try Task.checkCancellation()
        do {
            guard let size = try request.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size == request.byteCount, size <= PetImageDownloader.maximumBytes else { return false }
            let data = try Data(contentsOf: request.url)
            try Task.checkCancellation()
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == request.contentHash,
                  let image = try? PetImageDownloader.validate(data: data, mimeType: request.format.mimeType),
                  image.rowCount == request.rowCount else { return false }
            try Task.checkCancellation()
            return true
        } catch where isMissingFile(error) { return false }
    }

    nonisolated private static func isMissingFile(_ error: Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private func evict(preserving id: String) throws {
        guard let scope else { return }
        var retained = assets
        for asset in assets.sorted(by: { $0.accessedAt < $1.accessedAt }) {
            guard retained.reduce(0, { $0 + $1.byteCount }) > maximumCacheBytes else { break }
            if asset.id == selectedID || asset.id == id { continue }
            try FileManager.default.removeItem(at: fileURL(asset, scope: scope))
            retained = retained.filter { $0.filename != asset.filename }
        }
        assets = retained
        let names = Set(assets.map(\.filename)).union(["catalog.json"])
        for file in try FileManager.default.contentsOfDirectory(at: scopeURL(scope), includingPropertiesForKeys: nil) {
            if !names.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        }
    }

    private func load(scope: String) throws {
        let folder = scopeURL(scope)
        try protectDirectory(folder)
        let manifestURL = folder.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        guard let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumManifestBytes else { throw PetCatalogError.storage }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= Self.maximumManifestBytes else { throw PetCatalogError.storage }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.items.count <= 1_000, manifest.assets.count <= 1_000,
              manifest.items.allSatisfy({ PetCatalogItem.validID($0.id) && $0.name.count <= 80 }) else {
            throw PetCatalogError.storage
        }
        let valid = manifest.assets.compactMap { asset -> StoredAsset? in
            guard PetCatalogItem.validID(asset.id), asset.filename.range(of: "^[a-f0-9]{64}\\.atlas$", options: .regularExpression) != nil,
                  (0...PetImageDownloader.maximumBytes).contains(asset.byteCount), [9, 11].contains(asset.rowCount) else { return nil }
            let url = fileURL(asset, scope: scope)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == asset.byteCount else { return nil }
            return asset
        }
        items = manifest.items.map { PetCatalogItem(id: $0.id, name: $0.name, updatedAt: $0.updatedAt) }
        assets = valid
        selectedID = manifest.selectedID.flatMap { PetCatalogItem.validID($0) ? $0 : nil }
        try evict(preserving: selectedID ?? "")
    }

    private func persist() throws {
        guard let scope else { return }
        let manifest = Manifest(items: items.map { StoredItem(id: $0.id, name: $0.name, updatedAt: $0.updatedAt) },
                                assets: assets, selectedID: selectedID)
        let folder = scopeURL(scope)
        try protectDirectory(folder)
        let data = try JSONEncoder().encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw PetCatalogError.storage }
        try write(data, to: folder.appendingPathComponent("catalog.json"))
    }

    private func scopeURL(_ scope: String) -> URL { directory.appendingPathComponent(scope, isDirectory: true) }
    private func fileURL(_ asset: StoredAsset, scope: String) -> URL { scopeURL(scope).appendingPathComponent(asset.filename) }

    private func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        var mutableURL = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private struct Manifest: Codable {
        let items: [StoredItem]
        let assets: [StoredAsset]
        let selectedID: String?
    }
    private struct ImageRequest {
        let id: UUID
        let task: Task<URL?, Never>
        let waiters: Set<UUID>
        func adding(_ waiter: UUID) -> Self { Self(id: id, task: task, waiters: waiters.union([waiter])) }
    }
    private struct StoredItem: Codable { let id: String; let name: String; let updatedAt: String? }
    private struct StoredAsset: Codable, Sendable {
        let id: String
        let filename: String
        let format: PetImageFormat
        let rowCount: Int
        let byteCount: Int
        let updatedAt: String?
        let contentHash: String
        let accessedAt: Date
        func accessed(at date: Date) -> Self {
            Self(id: id, filename: filename, format: format, rowCount: rowCount, byteCount: byteCount,
                 updatedAt: updatedAt, contentHash: contentHash, accessedAt: date)
        }
    }
}
