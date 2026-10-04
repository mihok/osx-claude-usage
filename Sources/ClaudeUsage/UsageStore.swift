import AppKit
import ClaudeUsageCore
import Combine
import Foundation

/// Fetches usage on a schedule and publishes the latest snapshot.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: UsageError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var planName: String?
    /// The source that produced `snapshot`.
    @Published private(set) var snapshotSource: UsageSourceKind?
    @Published private(set) var nextRefreshAt: Date?

    private let settings: AppSettings
    private let client: UsageClient
    private let credentialsLoader = ClaudeCodeCredentialsLoader()
    private var scheduledRefresh: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var webOrganizationID: String?
    private var lastAttemptAt: Date?
    private var refreshQueued = false
    private var cancellables = Set<AnyCancellable>()
    private let isPreview: Bool

    init(settings: AppSettings) {
        self.settings = settings
        client = UsageClient(appVersion: AppInfo.version)
        isPreview = false

        settings.$dataSource
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.sourceDidChange() }
            .store(in: &cancellables)

        settings.$refreshInterval
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] interval in self?.intervalDidChange(interval) }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.schedule(after: 5) }
            .store(in: &cancellables)
    }

    /// A store with fixed data, used to render previews.
    init(settings: AppSettings, previewSnapshot: UsageSnapshot?, planName: String?, error: UsageError? = nil) {
        self.settings = settings
        client = UsageClient()
        isPreview = true
        snapshot = previewSnapshot
        snapshotSource = previewSnapshot == nil ? nil : settings.dataSource
        self.planName = planName
        lastError = error
    }

    func start() {
        guard !isPreview else { return }
        schedule(after: 0)
    }

    /// Fetch now, e.g. from the Refresh button.
    func refreshNow() {
        guard !isPreview, !isRefreshing else { return }
        Task { await refresh() }
    }

    /// Fetch when the popover opens if the data is getting old. Kept conservative because the
    /// usage endpoints rate-limit aggressively.
    func refreshIfStale() {
        guard !isPreview, !isRefreshing else { return }
        let reference = max(snapshot?.fetchedAt ?? .distantPast, lastAttemptAt ?? .distantPast)
        if Date().timeIntervalSince(reference) > 120 {
            refreshNow()
        }
    }

    var isStale: Bool {
        guard let snapshot else { return false }
        return RefreshSchedule.isStale(snapshot, interval: settings.refreshInterval)
    }

    /// Meters for the menu bar, honouring the user's choices.
    var menuBarMeters: [UsageMeter] {
        snapshot.map(settings.menuBarMeters(from:)) ?? []
    }

    // MARK: - Refreshing

    private func refresh() async {
        guard !isRefreshing else {
            // Something asked for fresh data mid-flight (e.g. the source changed); go again after.
            refreshQueued = true
            return
        }
        isRefreshing = true
        lastAttemptAt = Date()
        let source = settings.dataSource

        var failure: UsageError?
        do {
            let result = try await fetch(from: source)
            // Drop results for a source the user switched away from mid-flight.
            if source == settings.dataSource {
                snapshot = result.snapshot
                snapshotSource = source
                if let plan = result.planName { planName = plan }
                lastError = nil
                consecutiveFailures = 0
            }
        } catch let error as UsageError {
            failure = error
        } catch {
            failure = .network(error.localizedDescription)
        }

        if let failure, source == settings.dataSource {
            consecutiveFailures += 1
            lastError = failure
            if case .unauthorized = failure { webOrganizationID = nil }
        }
        isRefreshing = false

        if refreshQueued || source != settings.dataSource {
            refreshQueued = false
            schedule(after: 0)
            return
        }
        let delay = RefreshSchedule.nextDelay(
            interval: settings.refreshInterval,
            error: failure,
            consecutiveFailures: consecutiveFailures,
            nextReset: snapshot?.nextReset(after: Date())
        )
        schedule(after: delay)
    }

    private struct FetchResult {
        let snapshot: UsageSnapshot
        let planName: String?
    }

    private func fetch(from source: UsageSourceKind) async throws -> FetchResult {
        switch source {
        case .claudeCode:
            let loader = credentialsLoader
            // Reading the Keychain can block on an access prompt, so keep it off the main thread.
            let credentials = try await Task.detached(priority: .utility) { try loader.load() }.value
            guard !credentials.isExpired() else { throw UsageError.tokenExpired }
            let snapshot = try await client.fetchOAuthUsage(accessToken: credentials.accessToken)
            return FetchResult(snapshot: snapshot, planName: credentials.planName)

        case .claudeWeb:
            let stored = await Task.detached(priority: .utility) { CookieKeychain.read() }.value
            guard let stored, let cookie = ClaudeWebCookie.normalize(stored) else {
                throw UsageError.missingCookie
            }
            let result = try await client.fetchWebUsage(cookieHeader: cookie, organizationID: webOrganizationID)
            webOrganizationID = result.organizationID
            return FetchResult(snapshot: result.snapshot, planName: result.planName)
        }
    }

    private func schedule(after delay: TimeInterval) {
        guard !isPreview else { return }
        scheduledRefresh?.cancel()
        nextRefreshAt = Date().addingTimeInterval(delay)
        scheduledRefresh = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            // Run the fetch in its own task so rescheduling never cancels a request in flight.
            Task { await self.refresh() }
        }
    }

    // MARK: - Settings changes

    private func sourceDidChange() {
        snapshot = nil
        snapshotSource = nil
        planName = nil
        lastError = nil
        consecutiveFailures = 0
        webOrganizationID = nil
        schedule(after: 0.3)
    }

    /// Called after the user saves or removes the claude.ai cookie.
    func cookieDidChange() {
        webOrganizationID = nil
        if settings.dataSource == .claudeWeb {
            consecutiveFailures = 0
            schedule(after: 0.3)
        }
    }

    private func intervalDidChange(_ interval: TimeInterval) {
        guard !isRefreshing, lastError == nil else { return }
        let reference = snapshot?.fetchedAt ?? Date()
        schedule(after: max(interval - Date().timeIntervalSince(reference), 1))
    }
}
