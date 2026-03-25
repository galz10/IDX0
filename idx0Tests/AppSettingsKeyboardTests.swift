import XCTest
@testable import idx0

final class AppSettingsKeyboardTests: XCTestCase {
    func testDecodingMissingKeyboardFieldsUsesDefaults() throws {
        let json = """
        {
          "schemaVersion" : 4,
          "sidebarVisible" : true
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.keybindingMode, .both)
        XCTAssertEqual(decoded.modKeySetting, .commandOption)
        XCTAssertTrue(decoded.customKeybindings.isEmpty)
        XCTAssertFalse(decoded.hasSeenNiriOnboarding)
        XCTAssertFalse(decoded.cleanupOnClose)
        XCTAssertNil(decoded.terminalStartupCommandTemplate)
        XCTAssertNil(decoded.niri.defaultNewColumnWidth)
        XCTAssertNil(decoded.niri.defaultNewTileHeight)
        XCTAssertTrue(decoded.autoCheckForUpdates)
    }

    func testRoundTripPersistsKeyboardSettings() throws {
        var settings = AppSettings()
        settings.keybindingMode = .custom
        settings.modKeySetting = .optionControl
        settings.hasSeenNiriOnboarding = true
        settings.cleanupOnClose = true
        settings.terminalStartupCommandTemplate = "cd ${WORKDIR} && echo ${SESSION_ID}"
        settings.niri.defaultNewColumnWidth = 920
        settings.niri.defaultNewTileHeight = 540
        settings.autoCheckForUpdates = false
        settings.customKeybindings[ShortcutActionID.niriToggleOverview.rawValue] = KeyChord(
            key: .o,
            modifiers: [.option, .control]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.keybindingMode, .custom)
        XCTAssertEqual(decoded.modKeySetting, .optionControl)
        XCTAssertTrue(decoded.hasSeenNiriOnboarding)
        XCTAssertTrue(decoded.cleanupOnClose)
        XCTAssertEqual(decoded.terminalStartupCommandTemplate, "cd ${WORKDIR} && echo ${SESSION_ID}")
        XCTAssertEqual(decoded.niri.defaultNewColumnWidth, 920)
        XCTAssertEqual(decoded.niri.defaultNewTileHeight, 540)
        XCTAssertFalse(decoded.autoCheckForUpdates)
        XCTAssertEqual(
            decoded.customKeybindings[ShortcutActionID.niriToggleOverview.rawValue],
            KeyChord(key: .o, modifiers: [.option, .control])
        )
    }
}
