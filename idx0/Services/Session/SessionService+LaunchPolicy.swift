import Foundation

enum TerminalLaunchPolicyReason: String {
    case selectedSessionVisible
    case terminalSurfaceVisible
    case niriFocusedTerminalItem
    case explicitAction
    case activeSplitPaneVisible
    case relaunchSelectedSession
    case relaunchBackgroundQueue

    var marksVisibleControllers: Bool {
        switch self {
        case .selectedSessionVisible, .terminalSurfaceVisible, .niriFocusedTerminalItem, .activeSplitPaneVisible:
            return true
        case .explicitAction, .relaunchSelectedSession, .relaunchBackgroundQueue:
            return false
        }
    }
}

enum ControllerVisibilityState: Equatable {
    case visible
    case hiddenRunning
    case hiddenNotStarted
}

@MainActor
final class RestoreLaunchQueue {
    var onLaunch: ((UUID) -> Void)?

    private var task: Task<Void, Never>?
    private(set) var scheduledSessionIDs: [UUID] = []
    private let interLaunchDelayNanoseconds: UInt64

    init(interLaunchDelayNanoseconds: UInt64 = 180_000_000) {
        self.interLaunchDelayNanoseconds = interLaunchDelayNanoseconds
    }

    func schedule(selectedSessionID: UUID?, backgroundSessionIDs: [UUID]) {
        cancel()

        var ordered: [UUID] = []
        if let selectedSessionID {
            ordered.append(selectedSessionID)
        }
        for sessionID in backgroundSessionIDs where !ordered.contains(sessionID) {
            ordered.append(sessionID)
        }

        guard !ordered.isEmpty else { return }
        scheduledSessionIDs = ordered

        task = Task { [weak self] in
            guard let self else { return }
            for (index, sessionID) in ordered.enumerated() {
                if Task.isCancelled { return }
                self.onLaunch?(sessionID)
                self.scheduledSessionIDs.removeAll(where: { $0 == sessionID })

                if index < ordered.count - 1 {
                    try? await Task.sleep(nanoseconds: interLaunchDelayNanoseconds)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        scheduledSessionIDs.removeAll()
    }
}

extension SessionService {
    @discardableResult
    func requestLaunchForActiveTerminals(
        in sessionID: UUID,
        reason: TerminalLaunchPolicyReason
    ) -> Set<UUID> {
        guard sessions.contains(where: { $0.id == sessionID }) else { return [] }
        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)

        if let tabID = selectedTabID(for: sessionID) {
            return requestLaunchForTabTerminals(sessionID: sessionID, tabID: tabID, reason: reason)
        }

        return requestLaunch(for: sessionID, reason: reason).map { Set([$0.sessionID]) } ?? []
    }

    @discardableResult
    func requestLaunchForTabTerminals(
        sessionID: UUID,
        tabID: UUID,
        reason: TerminalLaunchPolicyReason
    ) -> Set<UUID> {
        guard let tab = tabState(sessionID: sessionID, tabID: tabID) else { return [] }
        let controllerIDs = Set(tab.allControllerIDs)

        for controllerID in controllerIDs {
            _ = requestLaunch(for: controllerID, ownerSessionID: sessionID, reason: reason)
        }

        if reason.marksVisibleControllers {
            controllerBecameVisible(sessionID: sessionID, controllerIDs: controllerIDs)
        }
        return controllerIDs
    }

    @discardableResult
    func requestLaunch(
        for sessionID: UUID,
        reason: TerminalLaunchPolicyReason
    ) -> TerminalSessionController? {
        guard let controller = ensureController(for: sessionID) else { return nil }
        _ = reason
        controller.requestLaunchIfNeeded()
        if reason.marksVisibleControllers {
            controllerBecameVisible(sessionID: sessionID, controllerIDs: [controller.sessionID])
        }
        return controller
    }

    @discardableResult
    func requestLaunch(
        for controllerID: UUID,
        ownerSessionID: UUID,
        reason: TerminalLaunchPolicyReason
    ) -> TerminalSessionController? {
        guard let controller = ensureController(forControllerID: controllerID, ownerSessionID: ownerSessionID) else {
            return nil
        }
        _ = reason
        controller.requestLaunchIfNeeded()
        if reason.marksVisibleControllers {
            var visible = visibleTerminalControllerIDsBySession[ownerSessionID] ?? []
            visible.insert(controllerID)
            visibleTerminalControllerIDsBySession[ownerSessionID] = visible
        }
        return controller
    }

    @discardableResult
    func launchFocusedNiriTerminalIfVisible(
        sessionID: UUID,
        reason: TerminalLaunchPolicyReason = .niriFocusedTerminalItem
    ) -> Set<UUID> {
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID] else {
            controllerBecameHidden(sessionID: sessionID)
            return []
        }

        guard !layout.isOverviewOpen else {
            controllerBecameHidden(sessionID: sessionID)
            return []
        }

        guard let focusedItemID = layout.camera.focusedItemID,
              let path = findNiriItemPath(layout: layout, itemID: focusedItemID)
        else {
            controllerBecameHidden(sessionID: sessionID)
            return []
        }

        switch layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref {
        case .terminal(let tabID):
            return requestLaunchForTabTerminals(sessionID: sessionID, tabID: tabID, reason: reason)
        case .browser, .app:
            controllerBecameHidden(sessionID: sessionID)
            return []
        }
    }

    func controllerBecameVisible(sessionID: UUID, controllerIDs: Set<UUID>) {
        guard !controllerIDs.isEmpty else { return }
        visibleTerminalControllerIDsBySession[sessionID] = controllerIDs
    }

    func controllerBecameVisible(sessionID: UUID, controllerIDs: [UUID]) {
        controllerBecameVisible(sessionID: sessionID, controllerIDs: Set(controllerIDs))
    }

    func controllerBecameHidden(sessionID: UUID) {
        visibleTerminalControllerIDsBySession.removeValue(forKey: sessionID)
    }

    func isControllerRunning(_ controllerID: UUID) -> Bool {
        guard let controller = runtimeControllers[controllerID] else { return false }
        if case .running = controller.runtimeState {
            return true
        }
        return false
    }

    func controllerVisibilityState(for controllerID: UUID) -> ControllerVisibilityState {
        let isVisible = visibleTerminalControllerIDsBySession.values.contains(where: { $0.contains(controllerID) })
        if isVisible {
            return .visible
        }
        return isControllerRunning(controllerID) ? .hiddenRunning : .hiddenNotStarted
    }

    func shouldLaunchVisibleTerminals(for sessionID: UUID) -> Bool {
        guard selectedSessionID == sessionID else { return false }
        guard settings.niriCanvasEnabled else { return true }

        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID],
              let focusedItemID = layout.camera.focusedItemID,
              let path = findNiriItemPath(layout: layout, itemID: focusedItemID)
        else {
            return false
        }

        guard !layout.isOverviewOpen else { return false }

        if case .terminal = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref {
            return true
        }
        return false
    }
}
