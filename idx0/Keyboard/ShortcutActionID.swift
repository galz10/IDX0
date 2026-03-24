import Foundation

enum ShortcutActionID: String, Codable, CaseIterable, Hashable {
    // Sessions
    case newSession
    case newQuickSession
    case newRepoWorktreeSession
    case newWorktreeSession
    case quickSwitchSession
    case focusNextSession
    case focusPreviousSession
    case renameSession
    case closeSession
    case relaunchSession
    case commandPalette
    case keyboardShortcuts
    case openSettings

    // Navigation
    case toggleSidebar
    case toggleWorkflowRail
    case toggleFocusMode
    case focusNextQueueItem
    case showDiff
    case showCheckpoints
    case openClipboardURL

    // Tabs and panes
    case newTab
    case nextTab
    case previousTab
    case closeTab
    case splitRight
    case splitDown
    case closePane
    case nextPane
    case previousPane
    case toggleBrowserSplit

    // Niri
    case niriAddTerminalRight
    case niriAddTaskBelow
    case niriAddBrowserTile
    case niriOpenAddTileMenu
    case niriFocusLeft
    case niriFocusDown
    case niriFocusUp
    case niriFocusRight
    case niriToggleOverview
    case niriConfirmSelection
    case niriToggleColumnTabbedDisplay
    case niriToggleSnap
    case niriFocusWorkspaceUp
    case niriFocusWorkspaceDown
    case niriMoveColumnToWorkspaceUp
    case niriMoveColumnToWorkspaceDown
    case niriToggleFocusedTileZoom
    case niriZoomInFocusedWebTile
    case niriZoomOutFocusedWebTile

    // Workflow
    case quickApprove
}

enum ShortcutSection: String, CaseIterable {
    case sessions
    case navigation
    case panes
    case niri
    case workflow

    var title: String {
        switch self {
        case .sessions:
            return "Sessions"
        case .navigation:
            return "Navigation"
        case .panes:
            return "Panes"
        case .niri:
            return "Niri Canvas"
        case .workflow:
            return "Workflow"
        }
    }
}

enum NiriShortcutCompatibility: String, CaseIterable {
    case exact
    case adapted
    case unsupported

    var displayLabel: String {
        switch self {
        case .exact:
            return "exact"
        case .adapted:
            return "adapted"
        case .unsupported:
            return "unsupported"
        }
    }
}
