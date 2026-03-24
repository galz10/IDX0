import Foundation

struct ShortcutBindingTemplate: Hashable {
    let key: ShortcutKey
    let fixedModifiers: Set<ShortcutModifier>
    let includesModKey: Bool

    init(
        key: ShortcutKey,
        fixedModifiers: Set<ShortcutModifier> = [],
        includesModKey: Bool = false
    ) {
        self.key = key
        self.fixedModifiers = fixedModifiers
        self.includesModKey = includesModKey
    }

    func resolved(modSetting: ModKeySetting) -> KeyChord {
        var modifiers = fixedModifiers
        if includesModKey {
            modifiers.formUnion(modSetting.modifiers)
        }
        return KeyChord(key: key, modifiers: modifiers)
    }
}

struct ShortcutDescriptor: Identifiable, Hashable {
    let id: ShortcutActionID
    let title: String
    let detail: String
    let section: ShortcutSection
    let niriActionName: String?
    let niriCompatibility: NiriShortcutCompatibility
    let remappable: Bool
    let macBindings: [ShortcutBindingTemplate]
    let niriBindings: [ShortcutBindingTemplate]

    var isNiriOnly: Bool {
        section == .niri
    }
}

struct ShortcutRegistry {
    static let shared = ShortcutRegistry()

    private(set) var descriptors: [ShortcutDescriptor]
    private let descriptorByID: [ShortcutActionID: ShortcutDescriptor]

    init(descriptors: [ShortcutDescriptor] = ShortcutRegistry.defaultDescriptors) {
        self.descriptors = descriptors
        self.descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    func descriptor(for action: ShortcutActionID) -> ShortcutDescriptor? {
        descriptorByID[action]
    }

    func descriptors(in section: ShortcutSection) -> [ShortcutDescriptor] {
        descriptors.filter { $0.section == section }
    }

    func customBinding(for action: ShortcutActionID, settings: AppSettings) -> KeyChord? {
        settings.customKeybindings[action.rawValue]
    }

    func resetBindingsForMode(_ mode: KeybindingMode, modSetting: ModKeySetting) -> [String: KeyChord] {
        var map: [String: KeyChord] = [:]
        for descriptor in descriptors where descriptor.remappable {
            let bindings = baseBindings(for: descriptor, mode: mode, modSetting: modSetting)
            if let first = primaryBinding(from: bindings, fallback: []) {
                map[descriptor.id.rawValue] = first
            }
        }
        return map
    }

    func activeBindings(for action: ShortcutActionID, settings: AppSettings) -> [KeyChord] {
        guard let descriptor = descriptorByID[action] else {
            return []
        }

        if settings.keybindingMode == .custom,
           let custom = customBinding(for: action, settings: settings) {
            return [custom]
        }

        return baseBindings(
            for: descriptor,
            mode: settings.keybindingMode,
            modSetting: settings.modKeySetting
        )
    }

    func primaryBinding(for action: ShortcutActionID, settings: AppSettings) -> KeyChord? {
        guard let descriptor = descriptorByID[action] else {
            return nil
        }

        if settings.keybindingMode == .custom,
           let custom = customBinding(for: action, settings: settings) {
            return custom
        }

        let macBindings = resolveBindings(descriptor.macBindings, modSetting: settings.modKeySetting)
        let niriBindings = resolveBindings(descriptor.niriBindings, modSetting: settings.modKeySetting)

        switch settings.keybindingMode {
        case .both, .macOSFirst, .custom:
            return primaryBinding(from: macBindings, fallback: niriBindings)
        case .niriFirst:
            return primaryBinding(from: niriBindings, fallback: macBindings)
        }
    }

    func displayLabel(for action: ShortcutActionID, settings: AppSettings) -> String? {
        primaryBinding(for: action, settings: settings)?.displayString
    }

    private func primaryBinding(from primary: [KeyChord], fallback: [KeyChord]) -> KeyChord? {
        primary.first ?? fallback.first
    }

    private func baseBindings(for descriptor: ShortcutDescriptor, mode: KeybindingMode, modSetting: ModKeySetting) -> [KeyChord] {
        let macBindings = resolveBindings(descriptor.macBindings, modSetting: modSetting)
        let niriBindings = resolveBindings(descriptor.niriBindings, modSetting: modSetting)

        switch mode {
        case .both, .custom:
            return dedupe(macBindings + niriBindings)
        case .macOSFirst:
            return macBindings.isEmpty ? niriBindings : macBindings
        case .niriFirst:
            return niriBindings.isEmpty ? macBindings : niriBindings
        }
    }

    private func resolveBindings(_ templates: [ShortcutBindingTemplate], modSetting: ModKeySetting) -> [KeyChord] {
        templates.map { $0.resolved(modSetting: modSetting) }
    }

    private func dedupe(_ chords: [KeyChord]) -> [KeyChord] {
        var seen: Set<KeyChord> = []
        var ordered: [KeyChord] = []
        for chord in chords where !seen.contains(chord) {
            seen.insert(chord)
            ordered.append(chord)
        }
        return ordered
    }

    private static let defaultDescriptors: [ShortcutDescriptor] = [
        ShortcutDescriptor(
            id: .newSession,
            title: "New Session (Default)",
            detail: "Create a new session using the default flow",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.n, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .newQuickSession,
            title: "New Quick Session",
            detail: "Create an instant terminal session",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.t, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .newRepoWorktreeSession,
            title: "New Repo/Worktree Session",
            detail: "Open structured setup for repo or worktree",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.n, [.command, .option])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .newWorktreeSession,
            title: "New Worktree Session",
            detail: "Create a new session from an existing worktree",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.n, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .quickSwitchSession,
            title: "Quick Switch Session",
            detail: "Jump to another session quickly",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.a, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .focusNextSession,
            title: "Next Session",
            detail: "Focus next session in the list",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.tab, [.control])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .focusPreviousSession,
            title: "Previous Session",
            detail: "Focus previous session in the list",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.tab, [.control, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .renameSession,
            title: "Rename Session",
            detail: "Rename the currently focused session",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.e, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .closeSession,
            title: "Close Session",
            detail: "Close the currently focused session",
            section: .sessions,
            niriActionName: "Close window/session",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.w, [.command])],
            niriBindings: [.niri(.q)]
        ),
        ShortcutDescriptor(
            id: .relaunchSession,
            title: "Relaunch Session",
            detail: "Relaunch the currently focused session",
            section: .sessions,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.r, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .commandPalette,
            title: "Command Palette",
            detail: "Open command palette",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.k, [.command])],
            niriBindings: [.niri(.p)]
        ),
        ShortcutDescriptor(
            id: .keyboardShortcuts,
            title: "Keyboard Shortcuts",
            detail: "Open the keyboard shortcut reference",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .openSettings,
            title: "Open Settings",
            detail: "Open IDX0 settings",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.comma, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .toggleSidebar,
            title: "Toggle Sidebar",
            detail: "Show or hide sidebar",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.b, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .toggleWorkflowRail,
            title: "Toggle Workflow Rail",
            detail: "Show or hide workflow rail",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.i, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .toggleFocusMode,
            title: "Toggle Focus Mode",
            detail: "Hide side panels for focus mode",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.f, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .focusNextQueueItem,
            title: "Focus Next Queue Item",
            detail: "Jump to highest-priority unresolved queue item",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.downArrow, [.command, .option, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .showDiff,
            title: "Show Diff",
            detail: "Toggle diff overlay",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.d, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .showCheckpoints,
            title: "Checkpoints",
            detail: "Toggle checkpoints sidebar",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.c, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .openClipboardURL,
            title: "Open Clipboard URL",
            detail: "Open clipboard URL in browser split",
            section: .navigation,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.o, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .newTab,
            title: "New Tab",
            detail: "Create a new tab in current session",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.t, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .nextTab,
            title: "Next Tab",
            detail: "Focus next tab",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.closeBracket, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .previousTab,
            title: "Previous Tab",
            detail: "Focus previous tab",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.openBracket, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .closeTab,
            title: "Close Tab",
            detail: "Close active tab",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.w, [.command, .option, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .splitRight,
            title: "Split Right",
            detail: "Split right (or add terminal right in Niri mode)",
            section: .panes,
            niriActionName: "Consume or expand column right",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.backslash, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .splitDown,
            title: "Split Down",
            detail: "Split down (or add task below in Niri mode)",
            section: .panes,
            niriActionName: "Consume or expand window down",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.backslash, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .closePane,
            title: "Close Pane / Tile",
            detail: "Close focused pane or tile",
            section: .panes,
            niriActionName: "Close column/window",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.w, [.command, .shift])],
            niriBindings: [.niri(.w), .niri(.q, fixed: [.shift])]
        ),
        ShortcutDescriptor(
            id: .nextPane,
            title: "Next Pane",
            detail: "Focus next pane",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.closeBracket, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .previousPane,
            title: "Previous Pane",
            detail: "Focus previous pane",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.openBracket, [.command])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .toggleBrowserSplit,
            title: "Toggle Browser Split",
            detail: "Show or hide browser split",
            section: .panes,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.b, [.command, .shift])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .niriAddTerminalRight,
            title: "Add Terminal Right",
            detail: "Add terminal tile to the right",
            section: .niri,
            niriActionName: "Spawn window right",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [
                .mac(.t, [.command, .option]),
                .mac(.backslash, [.command, .option]),
            ],
            niriBindings: [.niri(.t), .niri(.backslash)]
        ),
        ShortcutDescriptor(
            id: .niriAddTaskBelow,
            title: "Add Task Below",
            detail: "Add terminal tile below in current stack",
            section: .niri,
            niriActionName: "Spawn window down",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.backslash, [.command, .option, .shift])],
            niriBindings: [.niri(.backslash, fixed: [.shift])]
        ),
        ShortcutDescriptor(
            id: .niriAddBrowserTile,
            title: "Add Browser Tile",
            detail: "Add browser tile in current column",
            section: .niri,
            niriActionName: "Spawn browser helper tile",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.b, [.command, .option])],
            niriBindings: [.niri(.b)]
        ),
        ShortcutDescriptor(
            id: .niriOpenAddTileMenu,
            title: "Open Add Tile Menu",
            detail: "Open the Add Tile quick menu",
            section: .niri,
            niriActionName: "Open quick-add menu",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.a, [.command, .option])],
            niriBindings: [.niri(.a)]
        ),
        ShortcutDescriptor(
            id: .niriFocusLeft,
            title: "Focus Left",
            detail: "Move focus to left tile",
            section: .niri,
            niriActionName: "Focus column left",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.leftArrow, [.command, .option])],
            niriBindings: [.niri(.h)]
        ),
        ShortcutDescriptor(
            id: .niriFocusDown,
            title: "Focus Down",
            detail: "Move focus to tile below",
            section: .niri,
            niriActionName: "Focus window down",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.downArrow, [.command, .option])],
            niriBindings: [.niri(.j)]
        ),
        ShortcutDescriptor(
            id: .niriFocusUp,
            title: "Focus Up",
            detail: "Move focus to tile above",
            section: .niri,
            niriActionName: "Focus window up",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.upArrow, [.command, .option])],
            niriBindings: [.niri(.k)]
        ),
        ShortcutDescriptor(
            id: .niriFocusRight,
            title: "Focus Right",
            detail: "Move focus to right tile",
            section: .niri,
            niriActionName: "Focus column right",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.rightArrow, [.command, .option])],
            niriBindings: [.niri(.l)]
        ),
        ShortcutDescriptor(
            id: .niriToggleOverview,
            title: "Toggle Overview",
            detail: "Open or close overview",
            section: .niri,
            niriActionName: "Toggle overview",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.o, [.command, .option])],
            niriBindings: [.niri(.o)]
        ),
        ShortcutDescriptor(
            id: .niriConfirmSelection,
            title: "Confirm Overview Selection",
            detail: "Confirm selected tile in overview",
            section: .niri,
            niriActionName: "Confirm overview selection",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.returnKey, [])],
            niriBindings: []
        ),
        ShortcutDescriptor(
            id: .niriToggleColumnTabbedDisplay,
            title: "Toggle Column Tabbed Display",
            detail: "Switch focused column between normal and tabbed",
            section: .niri,
            niriActionName: "Toggle tabbed column",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.t, [.command, .option, .shift])],
            niriBindings: [.niri(.t, fixed: [.shift])]
        ),
        ShortcutDescriptor(
            id: .niriToggleSnap,
            title: "Toggle Snap",
            detail: "Toggle niri snap behavior",
            section: .niri,
            niriActionName: "Toggle edge/snap behavior",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.s, [.command, .option])],
            niriBindings: [.niri(.s)]
        ),
        ShortcutDescriptor(
            id: .niriFocusWorkspaceUp,
            title: "Focus Workspace Up",
            detail: "Move to previous workspace",
            section: .niri,
            niriActionName: "Focus workspace up",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.upArrow, [.command, .option, .control])],
            niriBindings: [.niri(.u), .niri(.pageUp)]
        ),
        ShortcutDescriptor(
            id: .niriFocusWorkspaceDown,
            title: "Focus Workspace Down",
            detail: "Move to next workspace",
            section: .niri,
            niriActionName: "Focus workspace down",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [.mac(.downArrow, [.command, .option, .control])],
            niriBindings: [.niri(.i), .niri(.pageDown)]
        ),
        ShortcutDescriptor(
            id: .niriMoveColumnToWorkspaceUp,
            title: "Move Column To Workspace Up",
            detail: "Move focused column to previous workspace",
            section: .niri,
            niriActionName: "Move column to workspace up",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [],
            niriBindings: [.niri(.u, fixed: [.shift]), .niri(.pageUp, fixed: [.shift])]
        ),
        ShortcutDescriptor(
            id: .niriMoveColumnToWorkspaceDown,
            title: "Move Column To Workspace Down",
            detail: "Move focused column to next workspace",
            section: .niri,
            niriActionName: "Move column to workspace down",
            niriCompatibility: .exact,
            remappable: true,
            macBindings: [],
            niriBindings: [.niri(.i, fixed: [.shift]), .niri(.pageDown, fixed: [.shift])]
        ),
        ShortcutDescriptor(
            id: .niriToggleFocusedTileZoom,
            title: "Toggle Focused Tile Zoom",
            detail: "Toggle focused tile max-zoom mode",
            section: .niri,
            niriActionName: "Toggle focused tile max zoom",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.f, [.command, .option])],
            niriBindings: [.niri(.f)]
        ),
        ShortcutDescriptor(
            id: .niriZoomInFocusedWebTile,
            title: "Zoom In Focused Web Tile",
            detail: "Increase zoom for focused browser-like tile",
            section: .niri,
            niriActionName: "Adjust web zoom",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.equal, [.command])],
            niriBindings: [.niri(.equal)]
        ),
        ShortcutDescriptor(
            id: .niriZoomOutFocusedWebTile,
            title: "Zoom Out Focused Web Tile",
            detail: "Decrease zoom for focused browser-like tile",
            section: .niri,
            niriActionName: "Adjust web zoom",
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.minus, [.command])],
            niriBindings: [.niri(.minus)]
        ),
        ShortcutDescriptor(
            id: .quickApprove,
            title: "Quick Approve",
            detail: "Send approve/yes input when prompt is detected",
            section: .workflow,
            niriActionName: nil,
            niriCompatibility: .adapted,
            remappable: true,
            macBindings: [.mac(.y, [.command])],
            niriBindings: []
        ),
    ]
}

private extension ShortcutBindingTemplate {
    static func mac(_ key: ShortcutKey, _ modifiers: Set<ShortcutModifier>) -> ShortcutBindingTemplate {
        ShortcutBindingTemplate(key: key, fixedModifiers: modifiers)
    }

    static func niri(_ key: ShortcutKey, fixed: Set<ShortcutModifier> = []) -> ShortcutBindingTemplate {
        ShortcutBindingTemplate(key: key, fixedModifiers: fixed, includesModKey: true)
    }
}
