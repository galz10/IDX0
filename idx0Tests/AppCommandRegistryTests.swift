@testable import idx0
import XCTest

final class AppCommandRegistryTests: XCTestCase {
  func testRegistryCoversAllShortcutDescriptors() {
    let shortcutIDs = Set(ShortcutRegistry.shared.descriptors.map(\.id))
    let registryIDs = Set(AppCommandRegistry.shared.descriptors.map(\.id))
    XCTAssertEqual(registryIDs, shortcutIDs)
  }

  func testCommandSurfaceSetsStayInParity() {
    let registry = AppCommandRegistry.shared
    XCTAssertEqual(registry.shortcutCommandIDs, registry.menuCommandIDs)
    XCTAssertEqual(registry.menuCommandIDs, registry.paletteCommandIDs)
  }

  func testIPCCommandConstantsAreUniqueAndNonEmpty() {
    let all = IPCCommand.all
    XCTAssertFalse(all.isEmpty)
    XCTAssertEqual(all.count, Set(all).count)
    XCTAssertFalse(all.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
  }

  func testCheckForUpdatesCommandIsPresentOnAllSurfaces() {
    let registry = AppCommandRegistry.shared
    XCTAssertNotNil(registry.descriptor(for: .checkForUpdates))
    XCTAssertTrue(registry.shortcutCommandIDs.contains(.checkForUpdates))
    XCTAssertTrue(registry.menuCommandIDs.contains(.checkForUpdates))
    XCTAssertTrue(registry.paletteCommandIDs.contains(.checkForUpdates))
  }
}
