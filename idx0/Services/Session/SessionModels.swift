import AppKit
import Foundation
import SwiftUI
import UserNotifications
import WebKit

struct WorktreeCleanupNotice: Identifiable {
    let id = UUID()
    let sessionTitle: String
    let repoPath: String?
    let branchName: String?
    let worktreePath: String
}

struct WorktreeDeletePrompt: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let sessionTitle: String
    let repoPath: String
    let branchName: String?
    let worktreePath: String
}

struct WorktreeInspectorRequest: Identifiable {
    let id = UUID()
    let repoPath: String
}

struct ProjectSessionSection: Identifiable {
    let group: ProjectGroup
    let sessions: [Session]

    var id: UUID { group.id }
}

struct WorktreeInspectionItem: Identifiable {
    let id = UUID()
    let repoPath: String
    let worktreePath: String
    let branchName: String
    let state: WorktreeState
}

struct SessionTerminalTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    var rootControllerID: UUID
    var paneTree: PaneNode?
    var focusedPaneControllerID: UUID?

    var paneCount: Int {
        paneTree?.terminalCount ?? 1
    }

    var activeControllerID: UUID {
        if let paneTree {
            if let focusedPaneControllerID, paneTree.terminalControllerIDs.contains(focusedPaneControllerID) {
                return focusedPaneControllerID
            }
            return paneTree.terminalControllerIDs.first ?? rootControllerID
        }
        return rootControllerID
    }

    var allControllerIDs: [UUID] {
        if let paneTree {
            return paneTree.terminalControllerIDs
        }
        return [rootControllerID]
    }
}

struct SessionTerminalTabItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let paneCount: Int
}

enum NiriItemRef: Equatable {
    case terminal(tabID: UUID)
    case browser
    case app(appID: String)

    var appID: String? {
        if case .app(let appID) = self {
            return appID
        }
        return nil
    }
}

enum NiriColumnDisplayMode: String, Codable, Equatable, CaseIterable {
    case normal
    case tabbed
}

struct NiriLayoutItem: Identifiable, Equatable {
    let id: UUID
    var ref: NiriItemRef
    var preferredHeight: CGFloat? = nil

    /// For terminal tiles: ordered list of all tab IDs displayed in this tile.
    /// When non-empty, the tile shows a tab bar and `activeTerminalTabID` determines
    /// which terminal is visible. When empty, falls back to the single tabID in `ref`.
    var terminalTabIDs: [UUID] = []
    var activeTerminalTabID: UUID? = nil

    /// The tab ID that should actually be rendered in this tile.
    var currentTerminalTabID: UUID? {
        if !terminalTabIDs.isEmpty {
            return activeTerminalTabID ?? terminalTabIDs.first
        }
        if case .terminal(let tabID) = ref {
            return tabID
        }
        return nil
    }

    /// Whether this tile should show its own tab bar.
    /// Shows for any terminal item so the user always has the "+" button to add tabs.
    var showsTabBar: Bool {
        if case .terminal = ref { return true }
        return false
    }

    /// Whether this tile has more than one tab.
    var hasMultipleTabs: Bool {
        terminalTabIDs.count > 1
    }
}

struct NiriColumn: Identifiable, Equatable {
    let id: UUID
    var items: [NiriLayoutItem]
    var focusedItemID: UUID?
    var displayMode: NiriColumnDisplayMode
    var preferredWidth: CGFloat? = nil
}

struct NiriWorkspace: Identifiable, Equatable {
    let id: UUID
    var columns: [NiriColumn]
}

enum NiriGestureAxis: Equatable {
    case undecided
    case horizontal
    case vertical
}

struct NiriGestureState: Equatable {
    var axis: NiriGestureAxis = .undecided
    var cumulative: CGSize = .zero
    var isActive = false
}

struct NiriCameraState: Equatable {
    var activeWorkspaceID: UUID?
    var activeColumnID: UUID?
    var focusedItemID: UUID?
}

/// Legacy layout bridge used during rollout. Old builds stored row/column cells.
struct NiriCanvasCell: Identifiable, Equatable {
    let id: UUID
    var column: Int
    var row: Int
    var item: NiriItemRef
}

struct NiriCanvasLayout: Equatable {
    var workspaces: [NiriWorkspace]
    var camera: NiriCameraState
    var isOverviewOpen: Bool
    var legacyCells: [NiriCanvasCell]

    static let empty = NiriCanvasLayout(
        workspaces: [],
        camera: NiriCameraState(),
        isOverviewOpen: false,
        legacyCells: []
    )
}

enum TileStatePersistenceSchema {
    static let currentVersion = 1
}

struct PersistedTileStateFilePayload: Codable {
    var schemaVersion: Int
    var sessions: [UUID: PersistedSessionTileState]

    init(
        schemaVersion: Int = TileStatePersistenceSchema.currentVersion,
        sessions: [UUID: PersistedSessionTileState] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
    }
}

struct PersistedSessionTileState: Codable {
    var tabs: [PersistedSessionTerminalTab]
    var selectedTabID: UUID?
    var niriLayout: PersistedNiriCanvasLayout?
}

struct PersistedSessionTerminalTab: Codable {
    var id: UUID
    var title: String
    var rootControllerID: UUID
    var paneTree: PersistedPaneNode?
    var focusedPaneControllerID: UUID?
}

indirect enum PersistedPaneNode: Codable {
    case terminal(id: UUID, controllerID: UUID)
    case split(
        id: UUID,
        direction: PaneSplitDirection,
        first: PersistedPaneNode,
        second: PersistedPaneNode,
        fraction: Double
    )
}

enum PersistedNiriItemRef: Codable {
    case terminal(tabID: UUID)
    case browser
    case app(appID: String)
}

struct PersistedNiriLayoutItem: Codable {
    var id: UUID
    var ref: PersistedNiriItemRef
    var preferredHeight: Double?
    var terminalTabIDs: [UUID]?
    var activeTerminalTabID: UUID?
}

struct PersistedNiriColumn: Codable {
    var id: UUID
    var items: [PersistedNiriLayoutItem]
    var focusedItemID: UUID?
    var displayMode: NiriColumnDisplayMode
    var preferredWidth: Double?
}

struct PersistedNiriWorkspace: Codable {
    var id: UUID
    var columns: [PersistedNiriColumn]
}

struct PersistedNiriCameraState: Codable {
    var activeWorkspaceID: UUID?
    var activeColumnID: UUID?
    var focusedItemID: UUID?
}

struct PersistedNiriCanvasLayout: Codable {
    var workspaces: [PersistedNiriWorkspace]
    var camera: PersistedNiriCameraState
    var isOverviewOpen: Bool
}

struct SwipeTracker {
    private struct Event {
        let delta: CGFloat
        let timestamp: TimeInterval
    }

    var historyLimit: TimeInterval = 0.150
    var deceleration: CGFloat = 0.997

    private var events: [Event] = []
    private(set) var position: CGFloat = 0

    init(historyLimit: TimeInterval = 0.150, deceleration: CGFloat = 0.997) {
        self.historyLimit = historyLimit
        self.deceleration = deceleration
    }

    mutating func push(delta: CGFloat, at timestamp: TimeInterval) {
        if let last = events.last, timestamp < last.timestamp {
            return
        }

        events.append(Event(delta: delta, timestamp: timestamp))
        position += delta
        trimHistory(now: timestamp)
    }

    func velocity() -> CGFloat {
        guard let first = events.first, let last = events.last else { return 0 }
        let dt = CGFloat(last.timestamp - first.timestamp)
        guard dt > 0 else { return 0 }
        let sum = events.reduce(CGFloat.zero) { partial, event in
            partial + event.delta
        }
        return sum / dt
    }

    func projectedEndPosition() -> CGFloat {
        let v = velocity()
        let clampedDeceleration = min(0.9999, max(0.0001, deceleration))
        return position - v / (1000 * log(clampedDeceleration))
    }

    mutating func reset() {
        events.removeAll(keepingCapacity: false)
        position = 0
    }

    private mutating func trimHistory(now: TimeInterval) {
        let minTimestamp = now - historyLimit
        if let firstKeptIndex = events.firstIndex(where: { $0.timestamp >= minTimestamp }) {
            if firstKeptIndex > 0 {
                events.removeFirst(firstKeptIndex)
            }
        }
    }
}

enum VSCodeBrowserDebugSetupError: LocalizedError {
    case launchDirectoryMissing(String)
    case invalidLaunchJSON(String)
    case browserNotFound
    case browserLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchDirectoryMissing(let path):
            return "Launch folder missing at \(path)."
        case .invalidLaunchJSON(let message):
            return "Could not update .vscode/launch.json: \(message)"
        case .browserNotFound:
            return "No supported Chromium browser was found (Chrome, Arc, Edge, Brave, Chromium)."
        case .browserLaunchFailed(let message):
            return "Failed to launch browser with remote debugging: \(message)"
        }
    }
}
