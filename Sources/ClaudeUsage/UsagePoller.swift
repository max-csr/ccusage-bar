import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

/// The state machine. Owns the poll timer, the in-memory refreshed token, and
/// the backoff / negative-cache policy. Publishes a `UsageSnapshot` and also
/// calls `onUpdate` so the AppKit status item can repaint.
@MainActor
final class UsagePoller: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot(status: .loading)

    /// Called on every snapshot change (main actor).
    var onUpdate: ((UsageSnapshot) -> Void)?

    private let client: UsageClient
    private let pollInterval: TimeInterval
    private var pollTimer: Timer?

    private var lastGood: UsageSnapshot?
    private var inMemoryToken: (token: String, expiresAtMs: Double?)?
    private var keychainNegativeUntil: Date?
    private var backoffUntil: Date?
    private var backoffStep = 0
    private var inFlight = false

    init(client: UsageClient, pollInterval: TimeInterval = 180) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func start() {
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer.tolerance = 30
        pollTimer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll(force: true) }
        }

        poll()
    }

    /// Manual refresh from the popover — clears backoff so it fires now.
    func pollNow() {
        backoffUntil = nil
        keychainNegativeUntil = nil
        poll(force: true)
    }

    private func poll(force: Bool = false) {
        if inFlight { return }
        if !force, let until = backoffUntil, until > Date() { return }
        inFlight = true
        Task { @MainActor in
            await performPoll()
            inFlight = false
        }
    }

    private func performPoll() async {
        // 1. Acquire an access token: prefer a still-valid in-memory refreshed
        //    token, otherwise read fresh from the keychain (riding along with
        //    the CLI's own refreshes).
        var token: String?
        var refreshTokenHint: String?   // captured if we read the keychain this poll
        if let mem = inMemoryToken, !isExpired(mem.expiresAtMs) {
            token = mem.token
        } else if let until = keychainNegativeUntil, until > Date() {
            emit(.noToken)
            return
        } else {
            switch await readCredentials() {
            case .success(let creds):
                keychainNegativeUntil = nil
                token = creds.accessToken
                refreshTokenHint = creds.refreshToken
            case .failure(.notFound):
                emit(.noToken)
                return
            case .failure:
                keychainNegativeUntil = Date().addingTimeInterval(60)
                emit(.noToken)
                return
            }
        }

        guard let accessToken = token else { emit(.noToken); return }

        // 2. Hit the usage endpoint.
        switch await client.fetchUsage(accessToken: accessToken) {
        case .success(let response):
            succeed(response)

        case .unauthorized:
            // 3. Reactive refresh (reuse the refresh token already read this poll), retry once.
            if let refreshed = await refreshToken(hint: refreshTokenHint) {
                inMemoryToken = (refreshed.accessToken, refreshed.expiresAtMs)
                if case .success(let response) = await client.fetchUsage(accessToken: refreshed.accessToken) {
                    succeed(response)
                    return
                }
            }
            // Token rejected and refresh didn't recover it — re-auth needed. Back off so we
            // don't re-hit the endpoint/keychain every poll; pollNow() clears it for a manual retry.
            inMemoryToken = nil
            backoffUntil = Date().addingTimeInterval(30 * 60)
            emit(.unauthorized)

        case .rateLimited(let retryAfter):
            applyBackoff(retryAfter: retryAfter)
            emit(.rateLimited)

        case .server, .transport, .decode:
            emit(.offline)
        }
    }

    private func succeed(_ response: UsageResponse) {
        backoffStep = 0
        backoffUntil = nil
        let snap = UsageSnapshot.from(response, status: .ok)
        // If the window just rolled over, re-poll soon so the drop shows quickly.
        scheduleRolloverPollIfNeeded(snap)
        lastGood = snap
        update(snap)
    }

    /// Keep the last good numbers visible but mark the new status.
    private func emit(_ status: UsageStatus) {
        if var snap = lastGood {
            snap.status = status
            update(snap)
        } else {
            update(UsageSnapshot(status: status))
        }
    }

    private func update(_ snap: UsageSnapshot) {
        snapshot = snap
        onUpdate?(snap)
    }

    private func applyBackoff(retryAfter: TimeInterval?) {
        backoffStep = min(backoffStep + 1, 4)
        let ladder: [TimeInterval] = [180, 360, 720, 1800]
        let base = ladder[min(backoffStep - 1, ladder.count - 1)]
        let delay = max(retryAfter ?? 0, base)
        backoffUntil = Date().addingTimeInterval(delay)
    }

    private func isExpired(_ expiresAtMs: Double?) -> Bool {
        guard let ms = expiresAtMs else { return true }
        return Date(timeIntervalSince1970: ms / 1000) <= Date().addingTimeInterval(60)
    }

    private func scheduleRolloverPollIfNeeded(_ snap: UsageSnapshot) {
        let now = Date()
        let nextReset = [snap.sessionResetsAt, snap.weeklyResetsAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
        guard let reset = nextReset else { return }
        let delay = reset.timeIntervalSince(now) + 5
        guard delay < pollInterval else { return }  // a normal poll will cover it
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 1) * 1_000_000_000))
            self.poll(force: true)
        }
    }

    // Run the blocking keychain read off the main actor.
    private func readCredentials() async -> Result<Credentials, KeychainError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: KeychainReader.readCredentials())
            }
        }
    }

    private func refreshToken(hint: String?) async -> UsageClient.RefreshResult? {
        if let hint { return await client.refresh(refreshToken: hint) }
        guard case .success(let creds) = await readCredentials(),
              let refresh = creds.refreshToken else { return nil }
        return await client.refresh(refreshToken: refresh)
    }
}
