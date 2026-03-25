import XCTest
@testable import idx0

final class AppUpdateActionMapperTests: XCTestCase {
    func testPrimaryActionMappingByStatus() {
        XCTAssertNil(AppUpdateActionMapper.primaryAction(for: .disabled))
        XCTAssertEqual(AppUpdateActionMapper.primaryAction(for: .idle), .check)
        XCTAssertNil(AppUpdateActionMapper.primaryAction(for: .checking))
        XCTAssertEqual(AppUpdateActionMapper.primaryAction(for: .upToDate), .check)
        XCTAssertEqual(AppUpdateActionMapper.primaryAction(for: .available), .download)
        XCTAssertNil(AppUpdateActionMapper.primaryAction(for: .downloading))
        XCTAssertEqual(AppUpdateActionMapper.primaryAction(for: .downloaded), .install)
        XCTAssertEqual(AppUpdateActionMapper.primaryAction(for: .error), .retry)
    }

    func testPrimaryActionTitlesMatchStatus() {
        XCTAssertEqual(AppUpdateActionMapper.primaryActionTitle(for: .idle), "Check for Updates")
        XCTAssertEqual(AppUpdateActionMapper.primaryActionTitle(for: .available), "Download Update")
        XCTAssertEqual(AppUpdateActionMapper.primaryActionTitle(for: .downloaded), "Install Update")
        XCTAssertEqual(AppUpdateActionMapper.primaryActionTitle(for: .error), "Retry")
        XCTAssertNil(AppUpdateActionMapper.primaryActionTitle(for: .checking))
    }
}
