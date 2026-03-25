import Foundation

@MainActor
protocol AppUpdateDriverProtocol: AnyObject {
    var onEvent: ((AppUpdateDriverEvent) -> Void)? { get set }
    func checkForUpdates(feedURLOverride: URL?, currentVersion: String)
    func downloadUpdate()
    func installUpdate()
}

enum AppUpdateDriverEvent: Equatable {
    case checkSucceeded(availableVersion: String?, downloadURL: URL?)
    case checkFailed(message: String)
    case downloadProgress(Double)
    case downloadCompleted
    case downloadFailed(message: String)
    case installFailed(message: String)
}

protocol UpdateSchedulerCancellable {
    func cancel()
}

@MainActor
protocol UpdateSchedulerProtocol {
    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable

    @discardableResult
    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable
}

protocol AppVersionProviding {
    var currentVersion: String { get }
}

protocol EnvironmentProviding {
    var isRunningTests: Bool { get }
    var isDebugBuild: Bool { get }
    var disableAutoUpdate: Bool { get }
    var updateFeedURLOverride: URL? { get }
    var defaultUpdateFeedURL: URL? { get }
}

struct BundleAppVersionProvider: AppVersionProviding {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var currentVersion: String {
        guard let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "0.0.0"
        }

        let cleaned = short.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "0.0.0" : cleaned
    }
}

struct ProcessEnvironmentProvider: EnvironmentProviding {
    private let environment: [String: String]
    private let bundle: Bundle

    init(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        self.environment = environment
        self.bundle = bundle
    }

    var isRunningTests: Bool {
        environment["XCTestBundlePath"] != nil || environment["XCTestConfigurationFilePath"] != nil
    }

    var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var disableAutoUpdate: Bool {
        environment["IDX0_DISABLE_AUTO_UPDATE"] == "1"
    }

    var updateFeedURLOverride: URL? {
        guard let raw = environment["IDX0_UPDATE_FEED_URL"], !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    var defaultUpdateFeedURL: URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: raw)
    }
}

@MainActor
final class TimerUpdateScheduler: UpdateSchedulerProtocol {
    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            Task { @MainActor in
                action()
            }
        }
        return TimerUpdateSchedulerToken(timer: timer)
    }

    @discardableResult
    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                action()
            }
        }
        return TimerUpdateSchedulerToken(timer: timer)
    }
}

private final class TimerUpdateSchedulerToken: UpdateSchedulerCancellable {
    private weak var timer: Timer?

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
    }
}
