import Foundation
import XCTest
@testable import idx0

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    func testStartupAndRepeatingChecksAreScheduledWhenEnabled() async {
        let driver = FakeUpdateDriver()
        let scheduler = FakeScheduler()
        let environment = FakeEnvironment()

        let service = AppUpdateService(
            driver: driver,
            scheduler: scheduler,
            versionProvider: FakeVersionProvider(currentVersion: "1.0.0"),
            environment: environment,
            autoCheckEnabledProvider: { true }
        )
        _ = service

        XCTAssertEqual(scheduler.oneShotIntervals, [AppUpdateService.startupDelay])
        XCTAssertEqual(scheduler.repeatingIntervals, [AppUpdateService.pollInterval])

        scheduler.fireOneShot(at: 0)
        XCTAssertEqual(driver.checkCalls.count, 1)
        XCTAssertEqual(driver.checkCalls.first?.currentVersion, "1.0.0")

        scheduler.fireRepeating(at: 0)
        XCTAssertEqual(driver.checkCalls.count, 1, "second check should be blocked while checking")

        driver.emit(.checkSucceeded(availableVersion: nil, downloadURL: nil))
        await flushMainActorTasks()
        scheduler.fireRepeating(at: 0)
        XCTAssertEqual(driver.checkCalls.count, 2)
    }

    func testManualCheckAndPrimaryActionsFollowStateMachine() async {
        let driver = FakeUpdateDriver()
        let service = makeService(driver: driver)

        service.checkNow()
        XCTAssertEqual(driver.checkCalls.count, 1)
        XCTAssertEqual(service.state.status, .checking)

        driver.emit(.checkSucceeded(availableVersion: "1.2.0", downloadURL: URL(string: "https://example.com/idx0.zip")))
        await flushMainActorTasks()
        XCTAssertEqual(service.state.status, .available)

        service.performPrimaryAction()
        XCTAssertEqual(driver.downloadCount, 1)
        XCTAssertEqual(service.state.status, .downloading)

        driver.emit(.downloadCompleted)
        await flushMainActorTasks()
        XCTAssertEqual(service.state.status, .downloaded)

        service.performPrimaryAction()
        XCTAssertEqual(driver.installCount, 1)
    }

    func testDisabledPolicySkipsSchedulingAndChecks() {
        let driver = FakeUpdateDriver()
        let scheduler = FakeScheduler()
        let service = AppUpdateService(
            driver: driver,
            scheduler: scheduler,
            versionProvider: FakeVersionProvider(currentVersion: "1.0.0"),
            environment: FakeEnvironment(isRunningTests: true),
            autoCheckEnabledProvider: { true }
        )

        XCTAssertEqual(service.state.status, .disabled)
        XCTAssertTrue(scheduler.oneShotIntervals.isEmpty)
        XCTAssertTrue(scheduler.repeatingIntervals.isEmpty)

        service.checkNow()
        XCTAssertTrue(driver.checkCalls.isEmpty)
    }

    func testAutoCheckToggleOffDisablesSchedulingButAllowsManualCheck() {
        let driver = FakeUpdateDriver()
        let scheduler = FakeScheduler()
        let service = AppUpdateService(
            driver: driver,
            scheduler: scheduler,
            versionProvider: FakeVersionProvider(currentVersion: "1.0.0"),
            environment: FakeEnvironment(),
            autoCheckEnabledProvider: { false }
        )

        XCTAssertEqual(service.state.status, .idle)
        XCTAssertTrue(scheduler.oneShotIntervals.isEmpty)
        XCTAssertTrue(scheduler.repeatingIntervals.isEmpty)

        service.checkNow()
        XCTAssertEqual(driver.checkCalls.count, 1)
    }

    func testCheckRequestsAreIgnoredDuringDownload() async {
        let driver = FakeUpdateDriver()
        let service = makeService(driver: driver)

        service.checkNow()
        driver.emit(.checkSucceeded(availableVersion: "1.2.0", downloadURL: URL(string: "https://example.com/idx0.zip")))
        await flushMainActorTasks()
        service.performPrimaryAction() // download

        service.checkNow()

        XCTAssertEqual(driver.downloadCount, 1)
        XCTAssertEqual(driver.checkCalls.count, 1)
        XCTAssertEqual(service.state.status, .downloading)
    }

    func testContextualActionTitlesFollowState() async {
        let driver = FakeUpdateDriver()
        let service = makeService(driver: driver)

        XCTAssertNil(service.contextualMenuActionTitle)

        service.checkNow()
        driver.emit(.checkSucceeded(availableVersion: "1.2.0", downloadURL: URL(string: "https://example.com/idx0.zip")))
        await flushMainActorTasks()
        XCTAssertEqual(service.contextualMenuActionTitle, "Download Update")

        service.performPrimaryAction()
        driver.emit(.downloadCompleted)
        await flushMainActorTasks()
        XCTAssertEqual(service.contextualMenuActionTitle, "Install Update")

        driver.emit(.installFailed(message: "nope"))
        await flushMainActorTasks()
        XCTAssertEqual(service.contextualMenuActionTitle, "Retry Update Check")
    }

    private func makeService(
        driver: FakeUpdateDriver,
        scheduler: FakeScheduler = FakeScheduler(),
        autoCheckEnabledProvider: @escaping () -> Bool = { true }
    ) -> AppUpdateService {
        AppUpdateService(
            driver: driver,
            scheduler: scheduler,
            versionProvider: FakeVersionProvider(currentVersion: "1.0.0"),
            environment: FakeEnvironment(),
            autoCheckEnabledProvider: autoCheckEnabledProvider,
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    private func flushMainActorTasks() async {
        await Task.yield()
        await Task.yield()
    }
}

private struct FakeVersionProvider: AppVersionProviding {
    let currentVersion: String
}

private struct FakeEnvironment: EnvironmentProviding {
    var isRunningTests: Bool = false
    var isDebugBuild: Bool = false
    var disableAutoUpdate: Bool = false
    var updateFeedURLOverride: URL? = nil
    var defaultUpdateFeedURL: URL? = URL(string: "https://example.com/appcast.xml")
}

@MainActor
private final class FakeUpdateDriver: AppUpdateDriverProtocol {
    struct CheckCall: Equatable {
        let feedURLOverride: URL?
        let currentVersion: String
    }

    var onEvent: ((AppUpdateDriverEvent) -> Void)?
    private(set) var checkCalls: [CheckCall] = []
    private(set) var downloadCount = 0
    private(set) var installCount = 0

    func checkForUpdates(feedURLOverride: URL?, currentVersion: String) {
        checkCalls.append(.init(feedURLOverride: feedURLOverride, currentVersion: currentVersion))
    }

    func downloadUpdate() {
        downloadCount += 1
    }

    func installUpdate() {
        installCount += 1
    }

    func emit(_ event: AppUpdateDriverEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class FakeScheduler: UpdateSchedulerProtocol {
    private final class Token: UpdateSchedulerCancellable {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private var oneShots: [(interval: TimeInterval, action: @Sendable @MainActor () -> Void, token: Token)] = []
    private var repeatings: [(interval: TimeInterval, action: @Sendable @MainActor () -> Void, token: Token)] = []

    var oneShotIntervals: [TimeInterval] {
        oneShots.map(\.interval)
    }

    var repeatingIntervals: [TimeInterval] {
        repeatings.map(\.interval)
    }

    @discardableResult
    func schedule(
        after interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable {
        let token = Token()
        oneShots.append((interval, action, token))
        return token
    }

    @discardableResult
    func scheduleRepeating(
        every interval: TimeInterval,
        _ action: @escaping @Sendable @MainActor () -> Void
    ) -> UpdateSchedulerCancellable {
        let token = Token()
        repeatings.append((interval, action, token))
        return token
    }

    func fireOneShot(at index: Int) {
        guard oneShots.indices.contains(index) else { return }
        let job = oneShots[index]
        if !job.token.isCancelled {
            job.action()
        }
    }

    func fireRepeating(at index: Int) {
        guard repeatings.indices.contains(index) else { return }
        let job = repeatings[index]
        if !job.token.isCancelled {
            job.action()
        }
    }
}
