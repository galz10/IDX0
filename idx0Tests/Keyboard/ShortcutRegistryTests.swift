import XCTest
@testable import idx0

final class ShortcutRegistryTests: XCTestCase {
    func testDefaultSettingsHaveNoShortcutConflicts() {
        let validator = ShortcutValidator()
        let conflicts = validator.conflicts(for: AppSettings())
        XCTAssertTrue(
            conflicts.isEmpty,
            conflicts.map(\.message).joined(separator: "\n")
        )
    }

    func testPrimaryBindingUsesMacDefaultInBothMode() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .both
        settings.modKeySetting = .commandOption

        let binding = registry.primaryBinding(for: .niriFocusLeft, settings: settings)

        XCTAssertEqual(binding?.key, .leftArrow)
        XCTAssertEqual(binding?.modifiers, [.command, .option])
    }

    func testPrimaryBindingUsesNiriDefaultInNiriFirstMode() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .niriFirst
        settings.modKeySetting = .commandOption

        let binding = registry.primaryBinding(for: .niriFocusLeft, settings: settings)

        XCTAssertEqual(binding?.key, .h)
        XCTAssertEqual(binding?.modifiers, [.command, .option])
    }

    func testNiriBindingUsesConfiguredModKey() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .niriFirst
        settings.modKeySetting = .control

        let binding = registry.primaryBinding(for: .niriFocusRight, settings: settings)

        XCTAssertEqual(binding?.key, .l)
        XCTAssertEqual(binding?.modifiers, [.control])
    }

    func testNiriAddTerminalRightUsesModTInNiriFirstMode() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .niriFirst
        settings.modKeySetting = .commandOption

        let binding = registry.primaryBinding(for: .niriAddTerminalRight, settings: settings)

        XCTAssertEqual(binding?.key, .t)
        XCTAssertEqual(binding?.modifiers, [.command, .option])
    }

    func testClosePaneUsesModWInNiriFirstMode() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .niriFirst
        settings.modKeySetting = .commandOption

        let binding = registry.primaryBinding(for: .closePane, settings: settings)

        XCTAssertEqual(binding?.key, .w)
        XCTAssertEqual(binding?.modifiers, [.command, .option])
    }

    func testNiriTabbedToggleUsesModShiftTInNiriFirstMode() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .niriFirst
        settings.modKeySetting = .commandOption

        let binding = registry.primaryBinding(for: .niriToggleColumnTabbedDisplay, settings: settings)

        XCTAssertEqual(binding?.key, .t)
        XCTAssertEqual(binding?.modifiers, [.command, .option, .shift])
    }

    func testCustomBindingOverridesPrimaryBinding() {
        let registry = ShortcutRegistry.shared
        var settings = AppSettings()
        settings.keybindingMode = .custom
        settings.customKeybindings[ShortcutActionID.niriFocusLeft.rawValue] = KeyChord(key: .x, modifiers: [.command])

        let binding = registry.primaryBinding(for: .niriFocusLeft, settings: settings)

        XCTAssertEqual(binding?.key, .x)
        XCTAssertEqual(binding?.modifiers, [.command])
    }

    func testValidatorDetectsConflictingCustomBindings() {
        let validator = ShortcutValidator()
        var settings = AppSettings()
        settings.keybindingMode = .custom
        let duplicate = KeyChord(key: .q, modifiers: [.command])
        settings.customKeybindings[ShortcutActionID.closeSession.rawValue] = duplicate
        settings.customKeybindings[ShortcutActionID.closePane.rawValue] = duplicate

        let conflicts = validator.conflicts(for: settings)

        XCTAssertFalse(conflicts.isEmpty)
    }
}
