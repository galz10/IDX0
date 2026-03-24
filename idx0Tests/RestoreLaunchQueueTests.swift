import XCTest
@testable import idx0

@MainActor
final class RestoreLaunchQueueTests: XCTestCase {
    func testSelectedSessionRunsFirstThenBackgroundOrder() async {
        let queue = RestoreLaunchQueue(interLaunchDelayNanoseconds: 2_000_000)
        let selected = UUID()
        let backgroundFirst = UUID()
        let backgroundSecond = UUID()

        var launched: [UUID] = []
        let launchedAll = expectation(description: "All sessions launched")
        launchedAll.expectedFulfillmentCount = 1

        queue.onLaunch = { sessionID in
            launched.append(sessionID)
            if launched.count == 3 {
                launchedAll.fulfill()
            }
        }

        queue.schedule(
            selectedSessionID: selected,
            backgroundSessionIDs: [backgroundFirst, backgroundSecond]
        )

        await fulfillment(of: [launchedAll], timeout: 2)
        XCTAssertEqual(launched, [selected, backgroundFirst, backgroundSecond])
    }
}
