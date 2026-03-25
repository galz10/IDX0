import Foundation

@MainActor
final class AppUpdateService: ObservableObject {
    static let startupDelay: TimeInterval = 15
    static let pollInterval: TimeInterval = 4 * 60 * 60

    @Published private(set) var state: AppUpdateState

    private let driver: AppUpdateDriverProtocol
    private let scheduler: UpdateSchedulerProtocol
    private let versionProvider: AppVersionProviding
    private let environment: EnvironmentProviding
    private let autoCheckEnabledProvider: () -> Bool
    private let now: () -> Date

    private var startupToken: UpdateSchedulerCancellable?
    private var repeatingToken: UpdateSchedulerCancellable?

    init(
        driver: AppUpdateDriverProtocol,
        scheduler: UpdateSchedulerProtocol,
        versionProvider: AppVersionProviding,
        environment: EnvironmentProviding,
        autoCheckEnabledProvider: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.driver = driver
        self.scheduler = scheduler
        self.versionProvider = versionProvider
        self.environment = environment
        self.autoCheckEnabledProvider = autoCheckEnabledProvider
        self.now = now

        self.state = AppUpdateState(currentVersion: versionProvider.currentVersion)

        self.driver.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleDriverEvent(event)
            }
        }

        refreshPolicy()
    }

    func refreshPolicy() {
        let enabled = !environment.isRunningTests && !environment.isDebugBuild && !environment.disableAutoUpdate
        state = AppUpdateReducer.reduce(state: state, event: .policyChanged(enabled: enabled))
        configureScheduling()
    }

    func checkNow() {
        checkNow(source: .manual)
    }

    func performPrimaryAction() {
        guard let action = AppUpdateActionMapper.primaryAction(for: state.status) else {
            return
        }

        switch action {
        case .check:
            checkNow(source: .manual)
        case .retry:
            checkNow(source: .retry)
        case .download:
            guard state.enabled else { return }
            state = AppUpdateReducer.reduce(state: state, event: .downloadStarted)
            driver.downloadUpdate()
        case .install:
            guard state.enabled else { return }
            state = AppUpdateReducer.reduce(state: state, event: .installStarted)
            driver.installUpdate()
        }
    }

    var canPerformPrimaryAction: Bool {
        AppUpdateActionMapper.primaryAction(for: state.status) != nil
    }

    var primaryActionTitle: String? {
        AppUpdateActionMapper.primaryActionTitle(for: state.status)
    }

    var contextualMenuActionTitle: String? {
        switch state.status {
        case .available:
            return "Download Update"
        case .downloaded:
            return "Install Update"
        case .error:
            return "Retry Update Check"
        default:
            return nil
        }
    }

    var statusDescription: String {
        switch state.status {
        case .disabled:
            return "Updates are disabled in this environment."
        case .idle:
            return autoCheckEnabledProvider() ? "Auto-check is enabled." : "Auto-check is disabled."
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "IDX0 is up to date."
        case .available:
            if let availableVersion = state.availableVersion {
                return "Version \(availableVersion) is available."
            }
            return "An update is available."
        case .downloading:
            let progress = Int((state.progress ?? 0) * 100)
            return "Downloading update (\(progress)%)."
        case .downloaded:
            return "Update downloaded and ready to install."
        case .error:
            return state.errorMessage ?? "Update check failed."
        }
    }

    private func configureScheduling() {
        startupToken?.cancel()
        repeatingToken?.cancel()
        startupToken = nil
        repeatingToken = nil

        guard state.enabled, autoCheckEnabledProvider() else {
            return
        }

        startupToken = scheduler.schedule(after: Self.startupDelay) { [weak self] in
            self?.checkNow(source: .startup)
        }

        repeatingToken = scheduler.scheduleRepeating(every: Self.pollInterval) { [weak self] in
            self?.checkNow(source: .scheduled)
        }
    }

    private func checkNow(source: AppUpdateCheckSource) {
        guard state.enabled else { return }
        guard state.status != .checking, state.status != .downloading else { return }

        state = AppUpdateReducer.reduce(state: state, event: .checkRequested(source: source))
        driver.checkForUpdates(
            feedURLOverride: environment.updateFeedURLOverride,
            currentVersion: state.currentVersion
        )
    }

    private func handleDriverEvent(_ event: AppUpdateDriverEvent) {
        switch event {
        case .checkSucceeded(let availableVersion, _):
            state = AppUpdateReducer.reduce(
                state: state,
                event: .checkSucceeded(availableVersion: availableVersion, checkedAt: now())
            )
        case .checkFailed(let message):
            state = AppUpdateReducer.reduce(
                state: state,
                event: .checkFailed(message: message, checkedAt: now())
            )
        case .downloadProgress(let value):
            state = AppUpdateReducer.reduce(state: state, event: .downloadProgress(value))
        case .downloadCompleted:
            state = AppUpdateReducer.reduce(state: state, event: .downloadSucceeded)
        case .downloadFailed(let message):
            state = AppUpdateReducer.reduce(state: state, event: .downloadFailed(message))
        case .installFailed(let message):
            state = AppUpdateReducer.reduce(state: state, event: .installFailed(message))
        }
    }
}
