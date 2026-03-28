import Foundation
@testable import idx0
import XCTest

final class AppcastScriptTests: XCTestCase {
  func testBuildXMLExcludesPrereleaseByDefault() {
    let entries = [
      makeEntry(version: "1.2.0", prerelease: false, publishedAt: Date(timeIntervalSince1970: 100)),
      makeEntry(version: "1.3.0-beta.1", prerelease: true, publishedAt: Date(timeIntervalSince1970: 200)),
    ]

    let xml = AppcastFeedBuilder.buildXML(entries: entries)

    XCTAssertTrue(xml.contains("IDX0 1.2.0"))
    XCTAssertFalse(xml.contains("IDX0 1.3.0-beta.1"))
    XCTAssertFalse(xml.contains("sparkle:shortVersionString=\"1.3.0-beta.1\""))
  }

  func testBuildXMLIncludesPrereleaseWhenRequested() {
    let entries = [
      makeEntry(version: "1.2.0", prerelease: false, publishedAt: Date(timeIntervalSince1970: 100)),
      makeEntry(version: "1.3.0-beta.1", prerelease: true, publishedAt: Date(timeIntervalSince1970: 200)),
    ]

    let xml = AppcastFeedBuilder.buildXML(entries: entries, includePrerelease: true)

    XCTAssertTrue(xml.contains("IDX0 1.2.0"))
    XCTAssertTrue(xml.contains("IDX0 1.3.0-beta.1"))
    XCTAssertTrue(xml.contains("sparkle:shortVersionString=\"1.3.0-beta.1\""))
  }

  private func makeEntry(version: String, prerelease: Bool, publishedAt: Date) -> AppcastReleaseEntry {
    AppcastReleaseEntry(
      version: version,
      downloadURL: URL(string: "https://example.com/IDX0-\(version)-mac.zip")!,
      length: 1024,
      publishedAt: publishedAt,
      prerelease: prerelease,
      signature: nil,
      minimumSystemVersion: "14.0",
      notesURL: nil
    )
  }
}
