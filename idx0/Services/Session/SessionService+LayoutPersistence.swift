import AppKit
import Foundation

extension SessionService {
    func restorePersistedTileStateIfNeeded() {
        if settings.cleanupOnClose {
            clearPersistedTileState()
            return
        }

        guard let payload = loadPersistedTileState() else { return }
        let validSessionIDs = Set(sessions.map(\.id))

        for (sessionID, state) in payload.sessions where validSessionIDs.contains(sessionID) {
            var seenTabIDs: Set<UUID> = []
            let restoredTabs: [SessionTerminalTab] = state.tabs.compactMap { (persistedTab: PersistedSessionTerminalTab) -> SessionTerminalTab? in
                let tab = restoreTab(from: persistedTab)
                guard seenTabIDs.insert(tab.id).inserted else { return nil }
                return tab
            }
            guard !restoredTabs.isEmpty else { continue }

            tabsBySession[sessionID] = restoredTabs

            if let selectedTabID = state.selectedTabID,
               restoredTabs.contains(where: { $0.id == selectedTabID }) {
                selectedTabIDBySession[sessionID] = selectedTabID
            } else {
                selectedTabIDBySession[sessionID] = restoredTabs.first?.id
            }

            for controllerID in Set(restoredTabs.flatMap { $0.allControllerIDs }) {
                ownerSessionIDByControllerID[controllerID] = sessionID
            }

            if let persistedLayout = state.niriLayout {
                let validTabIDs = Set(restoredTabs.map { $0.id })
                var restoredLayout = restoreNiriLayout(from: persistedLayout, validTabIDs: validTabIDs)
                migrateLegacyNiriCells(layout: &restoredLayout)
                normalizeNiriLayout(&restoredLayout)
                niriLayoutsBySession[sessionID] = restoredLayout
            }
            syncActivePaneState(for: sessionID)
        }
    }

    func loadPersistedTileState() -> PersistedTileStateFilePayload? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: tileStateFileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: tileStateFileURL)
            let decoded = try tileStateDecoder.decode(PersistedTileStateFilePayload.self, from: data)
            guard decoded.schemaVersion <= TileStatePersistenceSchema.currentVersion else {
                Logger.error("Unsupported tile-state schema version \(decoded.schemaVersion). Ignoring saved tile state.")
                return nil
            }
            return decoded
        } catch {
            Logger.error("Failed loading tile-state file: \(error.localizedDescription)")
            return nil
        }
    }

    func persistTileStateIfNeeded(settings: AppSettings) throws {
        if settings.cleanupOnClose {
            clearPersistedTileState()
            return
        }

        let validSessionIDs = Set(sessions.map(\.id))
        var statesBySession: [UUID: PersistedSessionTileState] = [:]

        for sessionID in validSessionIDs {
            guard let tabs = tabsBySession[sessionID], !tabs.isEmpty else { continue }

            let persistedTabs = tabs.map(persistedTab(from:))
            let selectedTabID = selectedTabIDBySession[sessionID]
            let persistedLayout = niriLayoutsBySession[sessionID].map(persistedNiriLayout(from:))
            statesBySession[sessionID] = PersistedSessionTileState(
                tabs: persistedTabs,
                selectedTabID: selectedTabID,
                niriLayout: persistedLayout
            )
        }

        guard !statesBySession.isEmpty else {
            clearPersistedTileState()
            return
        }

        let payload = PersistedTileStateFilePayload(
            schemaVersion: TileStatePersistenceSchema.currentVersion,
            sessions: statesBySession
        )
        let data = try tileStateEncoder.encode(payload)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: tileStateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: tileStateFileURL, options: .atomic)
    }

    func clearPersistedTileState() {
        try? FileManager.default.removeItem(at: tileStateFileURL)
    }

    func persistedTab(from tab: SessionTerminalTab) -> PersistedSessionTerminalTab {
        PersistedSessionTerminalTab(
            id: tab.id,
            title: tab.title,
            rootControllerID: tab.rootControllerID,
            paneTree: tab.paneTree.map(persistedPaneNode(from:)),
            focusedPaneControllerID: tab.focusedPaneControllerID
        )
    }

    func restoreTab(from persisted: PersistedSessionTerminalTab) -> SessionTerminalTab {
        SessionTerminalTab(
            id: persisted.id,
            title: persisted.title,
            rootControllerID: persisted.rootControllerID,
            paneTree: persisted.paneTree.map(restorePaneNode(from:)),
            focusedPaneControllerID: persisted.focusedPaneControllerID
        )
    }

    func persistedPaneNode(from paneNode: PaneNode) -> PersistedPaneNode {
        switch paneNode {
        case .terminal(let id, let controllerID):
            return .terminal(id: id, controllerID: controllerID)
        case .split(let id, let direction, let first, let second, let fraction):
            return .split(
                id: id,
                direction: direction,
                first: persistedPaneNode(from: first),
                second: persistedPaneNode(from: second),
                fraction: fraction
            )
        }
    }

    func restorePaneNode(from persisted: PersistedPaneNode) -> PaneNode {
        switch persisted {
        case .terminal(let id, let controllerID):
            return .terminal(id: id, controllerID: controllerID)
        case .split(let id, let direction, let first, let second, let fraction):
            return .split(
                id: id,
                direction: direction,
                first: restorePaneNode(from: first),
                second: restorePaneNode(from: second),
                fraction: fraction
            )
        }
    }

    func persistedNiriLayout(from layout: NiriCanvasLayout) -> PersistedNiriCanvasLayout {
        let persistedWorkspaces = layout.workspaces.map { workspace in
            PersistedNiriWorkspace(
                id: workspace.id,
                columns: workspace.columns.map { column in
                    PersistedNiriColumn(
                        id: column.id,
                        items: column.items.map { item in
                            PersistedNiriLayoutItem(
                                id: item.id,
                                ref: persistedNiriItemRef(from: item.ref),
                                preferredHeight: item.preferredHeight.map(Double.init)
                            )
                        },
                        focusedItemID: column.focusedItemID,
                        displayMode: column.displayMode,
                        preferredWidth: column.preferredWidth.map(Double.init)
                    )
                }
            )
        }

        return PersistedNiriCanvasLayout(
            workspaces: persistedWorkspaces,
            camera: PersistedNiriCameraState(
                activeWorkspaceID: layout.camera.activeWorkspaceID,
                activeColumnID: layout.camera.activeColumnID,
                focusedItemID: layout.camera.focusedItemID
            ),
            isOverviewOpen: false
        )
    }

    func restoreNiriLayout(from persisted: PersistedNiriCanvasLayout, validTabIDs: Set<UUID>) -> NiriCanvasLayout {
        let restoredWorkspaces: [NiriWorkspace] = persisted.workspaces.map { workspace in
            let restoredColumns: [NiriColumn] = workspace.columns.compactMap { column in
                let restoredItems: [NiriLayoutItem] = column.items.compactMap { item in
                    guard let ref = restoreNiriItemRef(from: item.ref, validTabIDs: validTabIDs) else { return nil }
                    return NiriLayoutItem(
                        id: item.id,
                        ref: ref,
                        preferredHeight: item.preferredHeight.map { CGFloat($0) }
                    )
                }
                guard !restoredItems.isEmpty else { return nil }

                let focusedItemID: UUID?
                if let candidate = column.focusedItemID,
                   restoredItems.contains(where: { $0.id == candidate }) {
                    focusedItemID = candidate
                } else {
                    focusedItemID = restoredItems.first?.id
                }

                return NiriColumn(
                    id: column.id,
                    items: restoredItems,
                    focusedItemID: focusedItemID,
                    displayMode: column.displayMode,
                    preferredWidth: column.preferredWidth.map { CGFloat($0) }
                )
            }
            return NiriWorkspace(id: workspace.id, columns: restoredColumns)
        }

        return NiriCanvasLayout(
            workspaces: restoredWorkspaces,
            camera: NiriCameraState(
                activeWorkspaceID: persisted.camera.activeWorkspaceID,
                activeColumnID: persisted.camera.activeColumnID,
                focusedItemID: persisted.camera.focusedItemID
            ),
            isOverviewOpen: false,
            legacyCells: []
        )
    }

    func persistedNiriItemRef(from ref: NiriItemRef) -> PersistedNiriItemRef {
        switch ref {
        case .terminal(let tabID):
            return .terminal(tabID: tabID)
        case .browser:
            return .browser
        case .app(let appID):
            return .app(appID: appID)
        }
    }

    func restoreNiriItemRef(from persisted: PersistedNiriItemRef, validTabIDs: Set<UUID>) -> NiriItemRef? {
        switch persisted {
        case .terminal(let tabID):
            guard validTabIDs.contains(tabID) else { return nil }
            return .terminal(tabID: tabID)
        case .browser:
            return .browser
        case .app(let appID):
            return .app(appID: appID)
        }
    }

    func applyRestoreBehaviorOnLaunch() {
        restoreCoordinator.apply(
            behavior: settings.restoreBehavior,
            selectedSessionID: selectedSessionID,
            sessions: &sessions,
            relaunchSession: { [weak self] sessionID in
                self?.relaunchSession(sessionID, launchReason: .relaunchSelectedSession)
            },
            relaunchAllSessions: { [weak self] in
                self?.relaunchAllSessions()
            }
        )
    }

    func ensureTabState(for sessionID: UUID, defaultRootControllerID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if tabsBySession[sessionID] == nil || tabsBySession[sessionID]?.isEmpty == true {
            let initialTab = SessionTerminalTab(
                id: UUID(),
                title: "Tab 1",
                rootControllerID: defaultRootControllerID,
                paneTree: nil,
                focusedPaneControllerID: nil
            )
            tabsBySession[sessionID] = [initialTab]
            selectedTabIDBySession[sessionID] = initialTab.id
        } else if selectedTabIDBySession[sessionID] == nil,
                  let first = tabsBySession[sessionID]?.first {
            selectedTabIDBySession[sessionID] = first.id
        }
        syncActivePaneState(for: sessionID)
    }

    func activeTabIndex(for sessionID: UUID) -> Int? {
        guard let tabs = tabsBySession[sessionID], !tabs.isEmpty else { return nil }
        let selected = selectedTabIDBySession[sessionID] ?? tabs[0].id
        if let index = tabs.firstIndex(where: { $0.id == selected }) {
            return index
        }
        return 0
    }

    func activeControllerID(for sessionID: UUID) -> UUID? {
        guard let tabs = tabsBySession[sessionID], let index = activeTabIndex(for: sessionID) else {
            return nil
        }
        return tabs[index].activeControllerID
    }

    func nextTabTitle(for tabs: [SessionTerminalTab]) -> String {
        var suffix = tabs.count + 1
        while tabs.contains(where: { $0.title == "Tab \(suffix)" }) {
            suffix += 1
        }
        return "Tab \(suffix)"
    }

    func syncActivePaneState(for sessionID: UUID) {
        guard let tabs = tabsBySession[sessionID], let index = activeTabIndex(for: sessionID) else {
            paneTrees.removeValue(forKey: sessionID)
            focusedPaneControllerID.removeValue(forKey: sessionID)
            return
        }
        let activeTab = tabs[index]
        if let paneTree = activeTab.paneTree {
            if paneTrees[sessionID] != paneTree {
                paneTrees[sessionID] = paneTree
            }
        } else {
            paneTrees.removeValue(forKey: sessionID)
        }
        if let focused = activeTab.focusedPaneControllerID {
            if focusedPaneControllerID[sessionID] != focused {
                focusedPaneControllerID[sessionID] = focused
            }
        } else {
            focusedPaneControllerID.removeValue(forKey: sessionID)
        }
    }

    func ensureNiriLayout(for sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if var existing = niriLayoutsBySession[sessionID] {
            migrateLegacyNiriCells(layout: &existing)
            normalizeNiriLayout(&existing)
            niriLayoutsBySession[sessionID] = existing
            clearNiriFocusedTileZoomIfInvalid(sessionID: sessionID, layout: existing)
            return
        }

        ensureTabState(for: sessionID, defaultRootControllerID: sessionID)
        guard let tabID = selectedTabID(for: sessionID) ?? tabsBySession[sessionID]?.first?.id else { return }

        let itemID = UUID()
        let item = makeNiriLayoutItem(id: itemID, ref: .terminal(tabID: tabID))
        let workspace = NiriWorkspace(
            id: UUID(),
            columns: [
                makeNiriColumn(
                    id: UUID(),
                    items: [item],
                    focusedItemID: itemID
                )
            ]
        )
        var layout = NiriCanvasLayout(
            workspaces: [workspace, NiriWorkspace(id: UUID(), columns: [])],
            camera: NiriCameraState(
                activeWorkspaceID: workspace.id,
                activeColumnID: workspace.columns.first?.id,
                focusedItemID: itemID
            ),
            isOverviewOpen: false,
            legacyCells: []
        )
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        clearNiriFocusedTileZoomIfInvalid(sessionID: sessionID, layout: layout)
    }

    struct NiriItemPath {
        let workspaceIndex: Int
        let columnIndex: Int
        let itemIndex: Int
    }
    func findNiriItemPath(layout: NiriCanvasLayout, itemID: UUID) -> NiriItemPath? {
        for workspaceIndex in layout.workspaces.indices {
            let workspace = layout.workspaces[workspaceIndex]
            for columnIndex in workspace.columns.indices {
                let column = workspace.columns[columnIndex]
                if let itemIndex = column.items.firstIndex(where: { $0.id == itemID }) {
                    return NiriItemPath(
                        workspaceIndex: workspaceIndex,
                        columnIndex: columnIndex,
                        itemIndex: itemIndex
                    )
                }
            }
        }
        return nil
    }

    func niriBrowserItemIDs(in layout: NiriCanvasLayout) -> [UUID] {
        layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .compactMap { item in
                if case .browser = item.ref {
                    return item.id
                }
                return nil
            }
    }

    func niriAppItemIDs(in layout: NiriCanvasLayout, appID: String) -> [UUID] {
        layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .compactMap { item in
                if item.ref.appID == appID {
                    return item.id
                }
                return nil
            }
    }

    func niriAppItemIDsByAppID(in layout: NiriCanvasLayout) -> [String: [UUID]] {
        var itemIDsByAppID: [String: [UUID]] = [:]
        layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .forEach { item in
                if let appID = item.ref.appID {
                    itemIDsByAppID[appID, default: []].append(item.id)
                }
            }
        return itemIDsByAppID
    }

    func activeWorkspaceIndex(layout: NiriCanvasLayout) -> Int? {
        if let activeWorkspaceID = layout.camera.activeWorkspaceID,
           let idx = layout.workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            return idx
        }
        return layout.workspaces.firstIndex(where: { !$0.columns.isEmpty }) ?? (layout.workspaces.isEmpty ? nil : 0)
    }

    func activeColumnIndex(layout: NiriCanvasLayout, workspaceIndex: Int) -> Int? {
        guard workspaceIndex >= 0, workspaceIndex < layout.workspaces.count else { return nil }
        let workspace = layout.workspaces[workspaceIndex]
        if let activeColumnID = layout.camera.activeColumnID,
           let idx = workspace.columns.firstIndex(where: { $0.id == activeColumnID }) {
            return idx
        }
        return workspace.columns.isEmpty ? nil : 0
    }

    func normalizeNiriLayout(_ layout: inout NiriCanvasLayout) {
        for workspaceIndex in layout.workspaces.indices {
            layout.workspaces[workspaceIndex].columns.removeAll(where: { $0.items.isEmpty })
            for columnIndex in layout.workspaces[workspaceIndex].columns.indices {
                if let preferredWidth = layout.workspaces[workspaceIndex].columns[columnIndex].preferredWidth {
                    layout.workspaces[workspaceIndex].columns[columnIndex].preferredWidth = max(180, min(preferredWidth, 2400))
                }
                for itemIndex in layout.workspaces[workspaceIndex].columns[columnIndex].items.indices {
                    if let preferredHeight = layout.workspaces[workspaceIndex].columns[columnIndex].items[itemIndex].preferredHeight {
                        layout.workspaces[workspaceIndex].columns[columnIndex].items[itemIndex].preferredHeight = max(120, min(preferredHeight, 2400))
                    }
                }
                if let focused = layout.workspaces[workspaceIndex].columns[columnIndex].focusedItemID,
                   layout.workspaces[workspaceIndex].columns[columnIndex].items.contains(where: { $0.id == focused }) {
                    continue
                }
                layout.workspaces[workspaceIndex].columns[columnIndex].focusedItemID = layout.workspaces[workspaceIndex].columns[columnIndex].items.first?.id
            }
        }

        let hadActiveWorkspaceID = layout.camera.activeWorkspaceID
        let activeWorkspaceWasEmpty: Bool = {
            guard let activeID = hadActiveWorkspaceID,
                  let activeWorkspace = layout.workspaces.first(where: { $0.id == activeID })
            else { return false }
            return activeWorkspace.columns.isEmpty
        }()

        var nonEmptyWorkspaces = layout.workspaces.filter { !$0.columns.isEmpty }
        let trailingWorkspaceID = activeWorkspaceWasEmpty ? (hadActiveWorkspaceID ?? UUID()) : UUID()
        nonEmptyWorkspaces.append(NiriWorkspace(id: trailingWorkspaceID, columns: []))
        layout.workspaces = nonEmptyWorkspaces

        if activeWorkspaceWasEmpty, let activeID = hadActiveWorkspaceID {
            layout.camera.activeWorkspaceID = activeID
            layout.camera.activeColumnID = nil
            layout.camera.focusedItemID = nil
            return
        }

        let preferredWorkspaceIndex: Int? = {
            if let activeID = hadActiveWorkspaceID,
               let index = layout.workspaces.firstIndex(where: { $0.id == activeID && !$0.columns.isEmpty }) {
                return index
            }
            return layout.workspaces.firstIndex(where: { !$0.columns.isEmpty })
        }()

        if let workspaceIndex = preferredWorkspaceIndex {
            let workspace = layout.workspaces[workspaceIndex]
            layout.camera.activeWorkspaceID = workspace.id
            if let columnIndex = workspace.columns.firstIndex(where: { $0.id == layout.camera.activeColumnID }) {
                let column = workspace.columns[columnIndex]
                layout.camera.activeColumnID = column.id
                layout.camera.focusedItemID = column.focusedItemID ?? column.items.first?.id
            } else if let column = workspace.columns.first {
                layout.camera.activeColumnID = column.id
                layout.camera.focusedItemID = column.focusedItemID ?? column.items.first?.id
            } else {
                layout.camera.activeColumnID = nil
                layout.camera.focusedItemID = nil
            }
            return
        }

        if let trailing = layout.workspaces.last {
            layout.camera.activeWorkspaceID = trailing.id
            layout.camera.activeColumnID = nil
            layout.camera.focusedItemID = nil
        }
    }

    func makeNiriLayoutItem(id: UUID, ref: NiriItemRef) -> NiriLayoutItem {
        NiriLayoutItem(
            id: id,
            ref: ref,
            preferredHeight: niriDefaultNewTileHeight()
        )
    }

    func makeNiriColumn(id: UUID, items: [NiriLayoutItem], focusedItemID: UUID?) -> NiriColumn {
        NiriColumn(
            id: id,
            items: items,
            focusedItemID: focusedItemID,
            displayMode: settings.niri.defaultColumnDisplayMode,
            preferredWidth: niriDefaultNewColumnWidth()
        )
    }

    func niriDefaultNewColumnWidth() -> CGFloat? {
        guard let configured = settings.niri.defaultNewColumnWidth else { return nil }
        return max(180, min(CGFloat(configured), 2400))
    }

    func niriDefaultNewTileHeight() -> CGFloat? {
        guard let configured = settings.niri.defaultNewTileHeight else { return nil }
        return max(120, min(CGFloat(configured), 2400))
    }

    func clearNiriFocusedTileZoomIfInvalid(sessionID: UUID, layout: NiriCanvasLayout) {
        guard let zoomedItemID = niriFocusedTileZoomItemIDBySession[sessionID] else { return }
        if findNiriItemPath(layout: layout, itemID: zoomedItemID) == nil {
            niriFocusedTileZoomItemIDBySession.removeValue(forKey: sessionID)
        }
    }

    func migrateLegacyNiriCells(layout: inout NiriCanvasLayout) {
        guard !layout.legacyCells.isEmpty, layout.workspaces.isEmpty else { return }

        let rows = Array(Set(layout.legacyCells.map(\.row))).sorted()
        var migrated: [NiriWorkspace] = []
        for row in rows {
            let rowCells = layout.legacyCells
                .filter { $0.row == row }
                .sorted { $0.column < $1.column }
            var columns: [NiriColumn] = []
            for cell in rowCells {
                let item = NiriLayoutItem(id: cell.id, ref: cell.item)
                columns.append(
                    NiriColumn(
                        id: UUID(),
                        items: [item],
                        focusedItemID: item.id,
                        displayMode: .normal
                    )
                )
            }
            migrated.append(NiriWorkspace(id: UUID(), columns: columns))
        }

        layout.workspaces = migrated
        layout.legacyCells = []
    }

    func removeNiriCells(sessionID: UUID, matchingTabID tabID: UUID) {
        guard var layout = niriLayoutsBySession[sessionID] else { return }
        for workspaceIndex in layout.workspaces.indices {
            for columnIndex in layout.workspaces[workspaceIndex].columns.indices {
                layout.workspaces[workspaceIndex].columns[columnIndex].items.removeAll {
                    if case .terminal(let existingTabID) = $0.ref {
                        return existingTabID == tabID
                    }
                    return false
                }
            }
        }

        if let selectedTabID = selectedTabIDBySession[sessionID],
           !layout.workspaces.contains(where: { workspace in
               workspace.columns.contains(where: { column in
                   column.items.contains(where: { item in
                       if case .terminal(let existingTabID) = item.ref {
                           return existingTabID == selectedTabID
                       }
                       return false
                   })
               })
           }),
           let workspaceIndex = activeWorkspaceIndex(layout: layout) {
            let itemID = UUID()
            let item = makeNiriLayoutItem(id: itemID, ref: .terminal(tabID: selectedTabID))
            let column = makeNiriColumn(
                id: UUID(),
                items: [item],
                focusedItemID: itemID
            )
            layout.workspaces[workspaceIndex].columns.append(column)
            layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
            layout.camera.activeColumnID = column.id
            layout.camera.focusedItemID = itemID
        }

        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        clearNiriFocusedTileZoomIfInvalid(sessionID: sessionID, layout: layout)
    }

    func removeNiriItem(sessionID: UUID, itemID: UUID) {
        guard var layout = niriLayoutsBySession[sessionID],
              let path = findNiriItemPath(layout: layout, itemID: itemID)
        else { return }

        let removed = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items.remove(at: path.itemIndex)
        var removedAppDescriptor: NiriAppDescriptor?
        if case .app(let removedAppID) = removed.ref {
            removedAppDescriptor = niriAppRegistry.descriptor(for: removedAppID)
        }
        if case .browser = removed.ref {
            niriBrowserControllersByItemID.removeValue(forKey: removed.id)
        } else if case .app = removed.ref, let descriptor = removedAppDescriptor {
            descriptor.stopTile(self, removed.id)
        }

        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        clearNiriFocusedTileZoomIfInvalid(sessionID: sessionID, layout: layout)
        if case .app(let removedAppID) = removed.ref,
           niriAppItemIDs(in: layout, appID: removedAppID).isEmpty {
            removedAppDescriptor?.cleanupSessionArtifacts?(self, sessionID)
        }

        guard let focusedID = layout.camera.focusedItemID,
              let focusedPath = findNiriItemPath(layout: layout, itemID: focusedID)
        else { return }

        let focusedRef = layout.workspaces[focusedPath.workspaceIndex].columns[focusedPath.columnIndex].items[focusedPath.itemIndex].ref
        switch focusedRef {
        case .terminal(let tabID):
            if selectedTabID(for: sessionID) != tabID {
                selectTab(sessionID: sessionID, tabID: tabID)
            }
            setLastFocusedSurface(for: sessionID, surface: .terminal)
        case .browser:
            _ = niriBrowserController(for: sessionID, itemID: focusedID)
            setLastFocusedSurface(for: sessionID, surface: .browser)
        case .app(let appID):
            ensureNiriAppController(for: sessionID, itemID: focusedID, appID: appID)
            setLastFocusedSurface(for: sessionID, surface: .app(appID: appID))
        }
    }

    func syncNiriFocusWithSelectedTab(sessionID: UUID) {
        guard let selectedTabID = selectedTabIDBySession[sessionID],
              var layout = niriLayoutsBySession[sessionID]
        else { return }

        if let item = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .first(where: {
                if case .terminal(let existingTabID) = $0.ref {
                    return existingTabID == selectedTabID
                }
                return false
            }) {
            niriLayoutsBySession[sessionID] = layout
            niriSelectItem(sessionID: sessionID, itemID: item.id)
            return
        }

        if let workspaceIndex = activeWorkspaceIndex(layout: layout) {
            let itemID = UUID()
            let item = makeNiriLayoutItem(id: itemID, ref: .terminal(tabID: selectedTabID))
            let column = makeNiriColumn(
                id: UUID(),
                items: [item],
                focusedItemID: itemID
            )
            layout.workspaces[workspaceIndex].columns.append(column)
            layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
            layout.camera.activeColumnID = column.id
            layout.camera.focusedItemID = itemID
            normalizeNiriLayout(&layout)
            niriLayoutsBySession[sessionID] = layout
            clearNiriFocusedTileZoomIfInvalid(sessionID: sessionID, layout: layout)
        }
    }

    func focusNiriWorkspace(sessionID: UUID, delta: Int) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let currentWorkspaceIndex = activeWorkspaceIndex(layout: layout)
        else { return }

        let targetWorkspaceIndex = max(0, min(layout.workspaces.count - 1, currentWorkspaceIndex + delta))
        guard targetWorkspaceIndex != currentWorkspaceIndex else { return }

        let targetWorkspace = layout.workspaces[targetWorkspaceIndex]
        layout.camera.activeWorkspaceID = targetWorkspace.id

        if targetWorkspace.columns.isEmpty {
            layout.camera.activeColumnID = nil
            layout.camera.focusedItemID = nil
            niriLayoutsBySession[sessionID] = layout
            return
        }

        let sourceColumnIndex = activeColumnIndex(layout: layout, workspaceIndex: currentWorkspaceIndex) ?? 0
        let targetColumnIndex = min(sourceColumnIndex, targetWorkspace.columns.count - 1)
        let targetColumn = targetWorkspace.columns[targetColumnIndex]
        if let targetItemID = targetColumn.focusedItemID ?? targetColumn.items.first?.id {
            niriLayoutsBySession[sessionID] = layout
            niriSelectItem(sessionID: sessionID, itemID: targetItemID)
        } else {
            niriLayoutsBySession[sessionID] = layout
        }
    }

    func moveNiriColumnToWorkspace(sessionID: UUID, delta: Int) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let sourceWorkspaceIndex = activeWorkspaceIndex(layout: layout),
              let sourceColumnIndex = activeColumnIndex(layout: layout, workspaceIndex: sourceWorkspaceIndex)
        else { return }

        let targetWorkspaceIndex = max(0, min(layout.workspaces.count - 1, sourceWorkspaceIndex + delta))
        guard targetWorkspaceIndex != sourceWorkspaceIndex else { return }

        let movedColumn = layout.workspaces[sourceWorkspaceIndex].columns.remove(at: sourceColumnIndex)
        let insertionIndex = layout.workspaces[targetWorkspaceIndex].columns.count
        layout.workspaces[targetWorkspaceIndex].columns.insert(movedColumn, at: insertionIndex)
        layout.camera.activeWorkspaceID = layout.workspaces[targetWorkspaceIndex].id
        layout.camera.activeColumnID = movedColumn.id
        layout.camera.focusedItemID = movedColumn.focusedItemID ?? movedColumn.items.first?.id
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
    }

}
