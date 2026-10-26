import Foundation
import Combine

@MainActor
final class PhoneConnectionSession: ObservableObject {
    let connectivity = CompanionConnectivity()
    @Published private(set) var status = "Open Rillby on your Apple Watch to connect."
    @Published private(set) var busy = false
    @Published private(set) var authorized = false
    private let vault = PhoneTransferVault()
    private let browser = PhoneOAuthBrowser()
    private var pending: PhoneCredentialTransfer?
    private var request: PhoneAuthorizationRequest?
    private var foreground = false
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var delivering = false
    private var operation = UUID()

    init() {
        connectivity.receive = { [weak self] message in await self?.receive(message) ?? .idle }
        connectivity.becameReachable = { [weak self] in self?.recover() }
        connectivity.activate()
    }
    func enterForeground() {
        foreground = true
        // Retry Keychain on unlock; do not assume a locked-device failure means no pending tokens.
        do {
            pending = try vault.load()
            if let pending { request = pending.request; scheduleExpiry(pending.request) }
        } catch { status = SignInError.storage.message; return }
        recover()
    }
    func enterBackground() { foreground = false }
    func start() {
        guard !busy, !delivering else { return }
        if pending != nil { recover(); return }
        busy = true
        authorized = false
        status = "Connecting to Apple Watch…"
        let operation = UUID(); self.operation = operation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await connectivity.send(.prepare)
                guard self.operation == operation else { return }
                guard case .begin(let request) = response else {
                    if case .failure(let reason) = response { status = reason }
                    else { status = "Open Rillby on the watch and try again." }
                    busy = false; task = nil; return
                }
                try await authorize(request, operation: operation)
            } catch { fail(error, operation: operation) }
        }
    }
    private func begin(_ request: PhoneAuthorizationRequest) {
        guard foreground, !busy, pending == nil else { return }
        busy = true; authorized = false
        let operation = UUID(); self.operation = operation
        task = Task { [weak self] in
            guard let self else { return }
            do { try await authorize(request, operation: operation) }
            catch { fail(error, operation: operation) }
        }
    }
    private func authorize(_ request: PhoneAuthorizationRequest, operation: UUID) async throws {
        try request.validate(now: .now)
        self.request = request
        scheduleExpiry(request)
        status = "Authorize your account in the iPhone browser."
        let account = try await browser.authorize(request)
        guard self.operation == operation, self.request == request else { throw CancellationError() }
        let transfer = PhoneCredentialTransfer(request: request, account: account)
        try vault.save(transfer)
        pending = transfer
        busy = false; task = nil
        status = "Account authorized. Sending the session to the watch…"
        recover()
    }
    private func fail(_ error: Error, operation: UUID) {
        guard self.operation == operation else { return }
        busy = false; task = nil
        status = error is CancellationError ? "Authorization canceled." : (error as? SignInError)?.message ?? "Couldn't authorize. Try again."
        if case .denied = error as? SignInError, let request {
            Task { [weak self] in _ = try? await self?.connectivity.send(.cancel(request)) }
            self.request = nil
        }
    }
    func cancel() {
        let request = request
        operation = UUID()
        task?.cancel(); task = nil
        busy = false
        do { try discard() } catch { status = SignInError.storage.message; return }
        status = "Authorization canceled."
        if let request { Task { [weak self] in _ = try? await self?.connectivity.send(.cancel(request)) } }
    }
    private func discard() throws {
        try vault.clear()
        pending = nil; request = nil
        expiryTask?.cancel(); expiryTask = nil
    }
    private func scheduleExpiry(_ request: PhoneAuthorizationRequest) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow))) } catch { return }
            guard let self, self.request == request else { return }
            cancel()
            status = "Authorization expired. Start a new attempt."
        }
    }
    private func receive(_ message: CompanionMessage) async -> CompanionMessage {
        switch message {
        case .begin(let request):
            guard (try? request.validate(now: .now)) != nil else { return .failure(SignInError.expired.message) }
            if let previous = self.request, previous != request {
                operation = UUID()
                task?.cancel(); task = nil
                busy = false
                do { try discard() } catch { return .failure(SignInError.storage.message) }
            }
            // Application context can be stale: query the Watch before presenting any browser.
            self.request = request
            if foreground { recover() }
            else { status = "Request received. Open Rillby to authorize." }
            return .status("Open Rillby on your iPhone to authorize.")
        case .cancel(let request):
            if self.request == request { cancel() }
            return .idle
        case .idle:
            return .idle // Only a direct query may invalidate a persisted transfer.
        default: return .failure(SignInError.invalidResponse.message)
        }
    }
    private func recover() {
        guard foreground, connectivity.reachable, !delivering, !busy else { return }
        delivering = true
        let operation = operation
        Task { [weak self] in
            guard let self else { return }
            defer { delivering = false }
            do {
                let response = try await connectivity.send(.query)
                guard self.operation == operation else { return }
                if let pending {
                    switch response {
                    case .acknowledgement(let receipt) where receipt == pending.receipt:
                        try complete()
                    case .begin(let active) where active == pending.request:
                        let reply = try await connectivity.send(.credentials(pending))
                        guard self.operation == operation else { return }
                        if case .acknowledgement(let receipt) = reply, receipt == pending.receipt {
                            try complete()
                        } else if case .failure(let reason) = reply { status = reason }
                        else { status = "Handoff pending. Open Rillby on the watch and retry." }
                    case .failure(let reason): status = reason
                    default:
                        try discard()
                        status = "The watch canceled or replaced this attempt. Start another sign-in."
                    }
                } else if case .begin(let request) = response {
                    begin(request)
                } else if case .acknowledgement = response {
                    authorized = true
                    status = "The watch already has its session. To switch accounts, sign out on the watch."
                }
            } catch {
                guard self.operation == operation else { return }
                status = pending == nil ? "Open Rillby on the watch and tap Continue with ChatGPT."
                    : "Session waiting for handoff. Open Rillby on the watch and retry."
            }
        }
    }
    private func complete() throws {
        try discard()
        authorized = true
        status = "Session saved on Apple Watch. The watch will renew its tokens on its own."
    }
}
