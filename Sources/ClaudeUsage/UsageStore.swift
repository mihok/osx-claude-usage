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
    @Published private(set) var nextRefreshAt: Date?

    private let settings: AppSettings
    private var scheduledRefresh: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastAttemptAt: Date?
    private var refreshQueued = false
    private var cancellables = Set<AnyCancellable>()
    private let isPreview: Bool

    init(settings: AppSettings) {
        self.settings = settings
        isPreview = false

        settings.$claudePath
            .removeDuplicates()
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.claudePathDidChange() }
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
        isPreview = true
        snapshot = previewSnapshot
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

    /// Fetch when the popover opens if the data is getting old. Kept conservative because Claude
    /// limits how often usage can be checked.
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
            // Something asked for fresh data mid-flight (e.g. a new Claude Code path); go again after.
            refreshQueued = true
            return
        }
        isRefreshing = true
        lastAttemptAt = Date()

        var failure: UsageError?
        do {
            let result = try await fetch(customPath: settings.claudePath, needsPlan: planName == nil)
            snapshot = result.snapshot
            if let plan = result.planName { planName = plan }
            lastError = nil
            consecutiveFailures = 0
        } catch let error as UsageError {
            failure = error
        } catch {
            failure = .cliFailed(error.localizedDescription)
        }

        if let failure {
            consecutiveFailures += 1
            lastError = failure
        }
        isRefreshing = false

        if refreshQueued {
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

    private struct FetchResult: Sendable {
        let snapshot: UsageSnapshot
        let planName: String?
    }

    /// Runs Claude Code's `/usage` off the main thread. Claude Code fetches the numbers with its
    /// own sign-in, renewing it when needed, so it doesn't have to be open.
    private nonisolated func fetch(customPath: String, needsPlan: Bool) async throws -> FetchResult {
        let shell = Self.loginShell
        let workingDirectory = Self.workingDirectory
        return try await Task.detached(priority: .utility) {
            let cli = try ClaudeCLI.resolve(
                customPath: customPath,
                shell: shell,
                workingDirectory: workingDirectory
            )
            let snapshot: UsageSnapshot
            do {
                snapshot = try cli.fetchUsage()
            } catch UsageError.usageUnavailable(let detail) {
                // Tell "signed out" apart from a temporary problem.
                if let status = try? cli.authStatus(), !status.loggedIn {
                    throw UsageError.notSignedIn
                }
                throw UsageError.usageUnavailable(detail)
            }
            let plan = needsPlan ? (try? cli.authStatus())?.planName : nil
            return FetchResult(snapshot: snapshot, planName: plan)
        }.value
    }

    /// The user's login shell, which knows the PATH Terminal uses.
    nonisolated static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// An empty folder to run Claude Code in, so no project's settings or CLAUDE.md apply.
    private nonisolated static var workingDirectory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("Claude Usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
            // Run the fetch in its own task so rescheduling never cancels one in flight.
            Task { await self.refresh() }
        }
    }

    // MARK: - Settings changes

    private func claudePathDidChange() {
        consecutiveFailures = 0
        planName = nil
        schedule(after: 0)
    }

    private func intervalDidChange(_ interval: TimeInterval) {
        guard !isRefreshing, lastError == nil else { return }
        let reference = snapshot?.fetchedAt ?? Date()
        schedule(after: max(interval - Date().timeIntervalSince(reference), 1))
    }
}
