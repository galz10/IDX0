import XCTest
@testable import idx0

@MainActor
final class TerminalMonitorServiceTests: XCTestCase {
    func testFocusedRunningSessionUsesFastPollingInterval() {
        let service = TerminalMonitorService()
        let state = TerminalMonitorService.SessionMonitorState()

        let interval = service.pollingInterval(
            for: state,
            now: Date(),
            isFocused: true,
            hasRunningSurface: true
        )

        XCTAssertEqual(interval, 2)
    }

    func testBackgroundRunningSessionUsesSlowPollingInterval() {
        let service = TerminalMonitorService()
        let state = TerminalMonitorService.SessionMonitorState()

        let interval = service.pollingInterval(
            for: state,
            now: Date(),
            isFocused: false,
            hasRunningSurface: true
        )

        XCTAssertEqual(interval, 8)
    }

    func testActivityEscalatesBackgroundSessionToFastPollingInterval() {
        let service = TerminalMonitorService()
        let now = Date()
        let state = TerminalMonitorService.SessionMonitorState(
            lastSnapshotTail: "",
            lastScanResult: .idle,
            lastPollTime: .distantPast,
            hasActivity: false,
            fastPollingUntil: now.addingTimeInterval(6)
        )

        let interval = service.pollingInterval(
            for: state,
            now: now,
            isFocused: false,
            hasRunningSurface: true
        )

        XCTAssertEqual(interval, 2)
    }

    func testNoRunningSurfaceSkipsToSlowPollingInterval() {
        let service = TerminalMonitorService()
        let state = TerminalMonitorService.SessionMonitorState()

        let interval = service.pollingInterval(
            for: state,
            now: Date(),
            isFocused: true,
            hasRunningSurface: false
        )

        XCTAssertEqual(interval, 8)
    }
}
