import XCTest
@testable import idx0

final class AppUpdateReducerTests: XCTestCase {
    func testCheckRequestTransitionsToChecking() {
        var state = AppUpdateState(currentVersion: "1.0.0")
        state.errorMessage = "old"
        state.progress = 0.4

        let next = AppUpdateReducer.reduce(state: state, event: .checkRequested(source: .manual))

        XCTAssertEqual(next.status, .checking)
        XCTAssertNil(next.errorMessage)
        XCTAssertNil(next.progress)
    }

    func testCheckSuccessWithAvailableVersionTransitionsToAvailable() {
        let checkedAt = Date(timeIntervalSince1970: 10)
        let state = AppUpdateState(currentVersion: "1.0.0", status: .checking)

        let next = AppUpdateReducer.reduce(
            state: state,
            event: .checkSucceeded(availableVersion: "1.1.0", checkedAt: checkedAt)
        )

        XCTAssertEqual(next.status, .available)
        XCTAssertEqual(next.availableVersion, "1.1.0")
        XCTAssertEqual(next.lastCheckedAt, checkedAt)
    }

    func testCheckSuccessWithNoVersionTransitionsToUpToDate() {
        let checkedAt = Date(timeIntervalSince1970: 11)
        let state = AppUpdateState(currentVersion: "1.1.0", status: .checking)

        let next = AppUpdateReducer.reduce(
            state: state,
            event: .checkSucceeded(availableVersion: nil, checkedAt: checkedAt)
        )

        XCTAssertEqual(next.status, .upToDate)
        XCTAssertNil(next.availableVersion)
        XCTAssertEqual(next.lastCheckedAt, checkedAt)
    }

    func testDownloadLifecycleTransitions() {
        let base = AppUpdateState(currentVersion: "1.0.0", availableVersion: "1.1.0", status: .available)

        let started = AppUpdateReducer.reduce(state: base, event: .downloadStarted)
        XCTAssertEqual(started.status, .downloading)
        XCTAssertEqual(started.progress, 0)

        let progress = AppUpdateReducer.reduce(state: started, event: .downloadProgress(0.65))
        XCTAssertEqual(progress.status, .downloading)
        XCTAssertEqual(try XCTUnwrap(progress.progress), 0.65, accuracy: 0.0001)

        let completed = AppUpdateReducer.reduce(state: progress, event: .downloadSucceeded)
        XCTAssertEqual(completed.status, .downloaded)
        XCTAssertEqual(completed.progress, 1)

        let failed = AppUpdateReducer.reduce(state: progress, event: .downloadFailed("network"))
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(failed.errorMessage, "network")
    }

    func testInstallFailureCanRetryToChecking() {
        let errored = AppUpdateReducer.reduce(
            state: AppUpdateState(currentVersion: "1.0.0", status: .downloaded),
            event: .installFailed("failed")
        )
        XCTAssertEqual(errored.status, .error)

        let retried = AppUpdateReducer.reduce(state: errored, event: .checkRequested(source: .retry))
        XCTAssertEqual(retried.status, .checking)
        XCTAssertNil(retried.errorMessage)
    }

    func testPolicyDisableAndReenableTransitions() {
        let state = AppUpdateState(currentVersion: "1.0.0", status: .upToDate)

        let disabled = AppUpdateReducer.reduce(state: state, event: .policyChanged(enabled: false))
        XCTAssertEqual(disabled.status, .disabled)
        XCTAssertFalse(disabled.enabled)

        let reenabled = AppUpdateReducer.reduce(state: disabled, event: .policyChanged(enabled: true))
        XCTAssertEqual(reenabled.status, .idle)
        XCTAssertTrue(reenabled.enabled)
    }

    func testCheckRequestIsIgnoredWhileDownloading() {
        let state = AppUpdateState(currentVersion: "1.0.0", status: .downloading)

        let next = AppUpdateReducer.reduce(state: state, event: .checkRequested(source: .manual))

        XCTAssertEqual(next, state)
    }
}
