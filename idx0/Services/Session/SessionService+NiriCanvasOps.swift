import AppKit
import Foundation
import SwiftUI

extension SessionService {
    // MARK: - Niri Canvas

    func niriLayout(for sessionID: UUID) -> NiriCanvasLayout {
        return niriLayoutsBySession[sessionID] ?? .empty
    }

    func ensureNiriLayoutState(for sessionID: UUID) {
        ensureNiriLayout(for: sessionID)
    }

#if DEBUG
    func setNiriLayoutForTesting(sessionID: UUID, layout: NiriCanvasLayout) {
        niriLayoutsBySession[sessionID] = layout
    }
#endif

    func niriSelectCell(sessionID: UUID, cellID: UUID) {
        niriSelectItem(sessionID: sessionID, itemID: cellID)
    }

    func niriSelectItem(sessionID: UUID, itemID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let path = findNiriItemPath(layout: layout, itemID: itemID) else { return }

        var column = layout.workspaces[path.workspaceIndex].columns[path.columnIndex]
        column.focusedItemID = itemID
        layout.workspaces[path.workspaceIndex].columns[path.columnIndex] = column

        let workspaceID = layout.workspaces[path.workspaceIndex].id
        let columnID = column.id
        layout.camera.activeWorkspaceID = workspaceID
        layout.camera.activeColumnID = columnID
        layout.camera.focusedItemID = itemID
        niriLayoutsBySession[sessionID] = layout

        switch column.items[path.itemIndex].ref {
        case .terminal(let tabID):
            if selectedTabID(for: sessionID) != tabID {
                selectTab(sessionID: sessionID, tabID: tabID)
            }
            niriPrimeTabController(sessionID: sessionID, tabID: tabID)
            if !layout.isOverviewOpen, selectedSessionID == sessionID {
                _ = requestLaunchForTabTerminals(
                    sessionID: sessionID,
                    tabID: tabID,
                    reason: .niriFocusedTerminalItem
                )
                ensureController(for: sessionID)?.focus()
            }
            setLastFocusedSurface(for: sessionID, surface: .terminal)
        case .browser:
            controllerBecameHidden(sessionID: sessionID)
            _ = niriBrowserController(for: sessionID, itemID: itemID)
            setLastFocusedSurface(for: sessionID, surface: .browser)
        case .app(let appID):
            controllerBecameHidden(sessionID: sessionID)
            ensureNiriAppController(for: sessionID, itemID: itemID, appID: appID)
            setLastFocusedSurface(for: sessionID, surface: .app(appID: appID))
        }
    }

    @discardableResult
    func niriAddTerminalRight(in sessionID: UUID) -> UUID? {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID] else { return nil }
        guard let tabID = createTab(in: sessionID, activate: false) else { return nil }
        niriPrimeTabController(sessionID: sessionID, tabID: tabID)
        guard let workspaceIndex = activeWorkspaceIndex(layout: layout) else { return nil }

        let itemID = UUID()
        let item = makeNiriLayoutItem(id: itemID, ref: .terminal(tabID: tabID))
        let newColumn = makeNiriColumn(id: UUID(), items: [item], focusedItemID: itemID)

        let insertionIndex: Int
        if let activeColumnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            insertionIndex = min(activeColumnIndex + 1, layout.workspaces[workspaceIndex].columns.count)
        } else {
            insertionIndex = layout.workspaces[workspaceIndex].columns.count
        }
        layout.workspaces[workspaceIndex].columns.insert(newColumn, at: insertionIndex)
        layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
        layout.camera.activeColumnID = newColumn.id
        layout.camera.focusedItemID = itemID
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        niriSelectItem(sessionID: sessionID, itemID: itemID)
        markTerminalFocused(for: sessionID)
        return itemID
    }

    @discardableResult
    func niriAddTaskBelow(in sessionID: UUID) -> UUID? {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID] else { return nil }
        guard let tabID = createTab(in: sessionID, activate: false) else { return nil }
        niriPrimeTabController(sessionID: sessionID, tabID: tabID)
        guard let workspaceIndex = activeWorkspaceIndex(layout: layout) else { return nil }

        let itemID = UUID()
        let item = makeNiriLayoutItem(id: itemID, ref: .terminal(tabID: tabID))

        if let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            layout.workspaces[workspaceIndex].columns[columnIndex].items.append(item)
            layout.workspaces[workspaceIndex].columns[columnIndex].focusedItemID = itemID
            layout.camera.activeColumnID = layout.workspaces[workspaceIndex].columns[columnIndex].id
        } else {
            let fallbackColumn = makeNiriColumn(id: UUID(), items: [item], focusedItemID: itemID)
            layout.workspaces[workspaceIndex].columns.append(fallbackColumn)
            layout.camera.activeColumnID = fallbackColumn.id
        }
        layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
        layout.camera.focusedItemID = itemID
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        niriSelectItem(sessionID: sessionID, itemID: itemID)
        markTerminalFocused(for: sessionID)
        return itemID
    }

    func niriPrimeTabController(sessionID: UUID, tabID: UUID) {
        guard let tab = tabState(sessionID: sessionID, tabID: tabID) else { return }
        let controllerID = tab.activeControllerID
        _ = ensureController(
            forControllerID: controllerID,
            ownerSessionID: sessionID
        )
    }

    @discardableResult
    func niriAddBrowserRight(in sessionID: UUID) -> UUID? {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID] else { return nil }

        guard let workspaceIndex = activeWorkspaceIndex(layout: layout) else { return nil }
        let itemID = UUID()
        let browserItem = makeNiriLayoutItem(id: itemID, ref: .browser)
        let browserColumn = makeNiriColumn(id: UUID(), items: [browserItem], focusedItemID: itemID)

        let insertionIndex: Int
        if let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            insertionIndex = min(columnIndex + 1, layout.workspaces[workspaceIndex].columns.count)
        } else {
            insertionIndex = layout.workspaces[workspaceIndex].columns.count
        }
        layout.workspaces[workspaceIndex].columns.insert(browserColumn, at: insertionIndex)
        layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
        layout.camera.activeColumnID = browserColumn.id
        layout.camera.focusedItemID = itemID
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        _ = niriBrowserController(for: sessionID, itemID: itemID)
        setLastFocusedSurface(for: sessionID, surface: .browser)
        return itemID
    }

    /// Generic app insertion path for singleton-style app tiles.
    @discardableResult
    func niriAddSingletonAppRight(in sessionID: UUID, appID: String) -> UUID? {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID] else { return nil }

        if let existingItemID = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .first(where: { item in
                item.ref.appID == appID
            })?.id {
            niriSelectItem(sessionID: sessionID, itemID: existingItemID)
            return existingItemID
        }

        guard let workspaceIndex = activeWorkspaceIndex(layout: layout) else { return nil }
        let itemID = UUID()
        let appItem = makeNiriLayoutItem(id: itemID, ref: .app(appID: appID))
        let appColumn = makeNiriColumn(id: UUID(), items: [appItem], focusedItemID: itemID)

        let insertionIndex: Int
        if let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            insertionIndex = min(columnIndex + 1, layout.workspaces[workspaceIndex].columns.count)
        } else {
            insertionIndex = layout.workspaces[workspaceIndex].columns.count
        }
        layout.workspaces[workspaceIndex].columns.insert(appColumn, at: insertionIndex)
        layout.camera.activeWorkspaceID = layout.workspaces[workspaceIndex].id
        layout.camera.activeColumnID = appColumn.id
        layout.camera.focusedItemID = itemID
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
        niriSelectItem(sessionID: sessionID, itemID: itemID)
        _ = ensureNiriAppController(for: sessionID, itemID: itemID, appID: appID)
        setLastFocusedSurface(for: sessionID, surface: .app(appID: appID))
        return itemID
    }

    @discardableResult
    func niriAddAppRight(in sessionID: UUID, appID: String) -> UUID? {
        guard let descriptor = niriAppRegistry.descriptor(for: appID) else { return nil }
        return descriptor.startTile(self, sessionID)
    }

    func retryNiriAppTile(sessionID: UUID, itemID: UUID, appID: String) {
        guard let descriptor = niriAppRegistry.descriptor(for: appID) else { return }
        descriptor.retryTile(self, sessionID, itemID)
    }

    func niriAppTileView(sessionID: UUID, itemID: UUID, appID: String) -> AnyView? {
        guard let descriptor = niriAppRegistry.descriptor(for: appID) else { return nil }
        return descriptor.makeTileView(self, sessionID, itemID)
    }

    @discardableResult
    func ensureNiriAppController(for sessionID: UUID, itemID: UUID, appID: String) -> (any NiriAppTileRuntimeControlling)? {
        guard sessions.contains(where: { $0.id == sessionID }) else { return nil }
        guard let layout = niriLayoutsBySession[sessionID],
              let path = findNiriItemPath(layout: layout, itemID: itemID)
        else { return nil }

        guard case .app(let actualAppID) = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref,
              actualAppID == appID else {
            return nil
        }

        if let existing = niriAppController(for: itemID, appID: appID) {
            return existing
        }

        guard let descriptor = niriAppRegistry.descriptor(for: appID),
              let controller = descriptor.ensureController(self, sessionID, itemID) else {
            return nil
        }

        setNiriAppController(controller, for: itemID, appID: appID)
        return controller
    }

    func niriFocusNeighbor(sessionID: UUID, horizontal: Int = 0, vertical: Int = 0) {
        guard horizontal != 0 || vertical != 0 else { return }
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = activeWorkspaceIndex(layout: layout) else { return }

        // Clear text selection on the current terminal before moving focus
        controller(for: sessionID)?.clearSelection()

        if horizontal != 0 {
            guard let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) else { return }
            let columns = layout.workspaces[workspaceIndex].columns
            let targetColumnIndex = max(0, min(columns.count - 1, columnIndex + horizontal))
            guard targetColumnIndex != columnIndex else { return }

            let targetColumn = columns[targetColumnIndex]
            guard !targetColumn.items.isEmpty else { return }

            let targetItemID: UUID
            if layout.isOverviewOpen {
                let sourceColumn = columns[columnIndex]
                let sourceFocusedItemID = sourceColumn.focusedItemID
                    ?? layout.camera.focusedItemID
                    ?? sourceColumn.items.first?.id
                let sourceItemIndex = sourceFocusedItemID.flatMap { focusedID in
                    sourceColumn.items.firstIndex(where: { $0.id == focusedID })
                } ?? 0
                let targetItemIndex = min(sourceItemIndex, targetColumn.items.count - 1)
                targetItemID = targetColumn.items[targetItemIndex].id
            } else {
                targetItemID = targetColumn.focusedItemID ?? targetColumn.items[0].id
            }

            niriSelectItem(sessionID: sessionID, itemID: targetItemID)
            return
        }

        if let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            let column = layout.workspaces[workspaceIndex].columns[columnIndex]
            let currentItemID = column.focusedItemID ?? layout.camera.focusedItemID ?? column.items.first?.id
            if column.items.count > 1, let currentItemID, let currentIndex = column.items.firstIndex(where: { $0.id == currentItemID }) {
                let targetItemIndex = currentIndex + vertical
                if targetItemIndex >= 0, targetItemIndex < column.items.count {
                    niriSelectItem(sessionID: sessionID, itemID: column.items[targetItemIndex].id)
                    return
                }
            }
        }
        if vertical > 0 {
            focusNiriWorkspaceDown(sessionID: sessionID)
        } else {
            focusNiriWorkspaceUp(sessionID: sessionID)
        }
    }

    func focusNiriWorkspaceDown(sessionID: UUID) {
        focusNiriWorkspace(sessionID: sessionID, delta: 1)
    }

    func focusNiriWorkspaceUp(sessionID: UUID) {
        focusNiriWorkspace(sessionID: sessionID, delta: -1)
    }

    func moveNiriColumnToWorkspaceDown(sessionID: UUID) {
        moveNiriColumnToWorkspace(sessionID: sessionID, delta: 1)
    }

    func moveNiriColumnToWorkspaceUp(sessionID: UUID) {
        moveNiriColumnToWorkspace(sessionID: sessionID, delta: -1)
    }

    func toggleNiriOverview(sessionID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID] else { return }
        layout.isOverviewOpen.toggle()
        if layout.isOverviewOpen {
            niriFocusedTileZoomItemIDBySession.removeValue(forKey: sessionID)
        }
        niriLayoutsBySession[sessionID] = layout
    }

    func niriFocusedTileZoomItemID(for sessionID: UUID) -> UUID? {
        guard let zoomedItemID = niriFocusedTileZoomItemIDBySession[sessionID] else { return nil }
        guard let layout = niriLayoutsBySession[sessionID],
              findNiriItemPath(layout: layout, itemID: zoomedItemID) != nil else {
            niriFocusedTileZoomItemIDBySession.removeValue(forKey: sessionID)
            return nil
        }
        return zoomedItemID
    }

    @discardableResult
    func toggleNiriFocusedTileZoom(sessionID: UUID) -> Bool {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let focusedItemID = layout.camera.focusedItemID,
              findNiriItemPath(layout: layout, itemID: focusedItemID) != nil else {
            return false
        }

        if layout.isOverviewOpen {
            layout.isOverviewOpen = false
            niriLayoutsBySession[sessionID] = layout
        }

        if niriFocusedTileZoomItemIDBySession[sessionID] == focusedItemID {
            niriFocusedTileZoomItemIDBySession.removeValue(forKey: sessionID)
        } else {
            niriFocusedTileZoomItemIDBySession[sessionID] = focusedItemID
        }
        return true
    }

    func clearNiriFocusedTileZoom(sessionID: UUID) {
        niriFocusedTileZoomItemIDBySession.removeValue(forKey: sessionID)
    }

    func toggleNiriColumnTabbedDisplay(sessionID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = activeWorkspaceIndex(layout: layout),
              let columnIndex = activeColumnIndex(layout: layout, workspaceIndex: workspaceIndex) else { return }
        let mode = layout.workspaces[workspaceIndex].columns[columnIndex].displayMode
        layout.workspaces[workspaceIndex].columns[columnIndex].displayMode = mode == .normal ? .tabbed : .normal
        niriLayoutsBySession[sessionID] = layout
    }

    func closeNiriItem(sessionID: UUID, itemID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID],
              let path = findNiriItemPath(layout: layout, itemID: itemID)
        else { return }

        let item = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex]
        switch item.ref {
        case .terminal:
            guard let tabs = tabsBySession[sessionID], tabs.count > 1 else { return }
            // Focus this item first so closeActiveTab removes the right one
            niriSelectItem(sessionID: sessionID, itemID: itemID)
            closeActiveTab(in: sessionID)
        case .browser:
            removeNiriItem(sessionID: sessionID, itemID: itemID)
        case .app:
            removeNiriItem(sessionID: sessionID, itemID: itemID)
        }
    }

    func closeNiriFocusedItem(in sessionID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard let layout = niriLayoutsBySession[sessionID],
              let focusedItemID = layout.camera.focusedItemID,
              let path = findNiriItemPath(layout: layout, itemID: focusedItemID)
        else { return }

        let item = layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex]
        switch item.ref {
        case .terminal(let tabID):
            guard let tabs = tabsBySession[sessionID], tabs.count > 1 else { return }
            if selectedTabID(for: sessionID) != tabID {
                selectTab(sessionID: sessionID, tabID: tabID)
            }
            closeActiveTab(in: sessionID)
        case .browser:
            removeNiriItem(sessionID: sessionID, itemID: focusedItemID)
        case .app:
            removeNiriItem(sessionID: sessionID, itemID: focusedItemID)
        }
    }

    func niriSetColumnWidths(
        sessionID: UUID,
        workspaceID: UUID,
        leftColumnID: UUID,
        leftWidth: CGFloat,
        rightColumnID: UUID,
        rightWidth: CGFloat
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let leftColumnIndex = layout.workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == leftColumnID }),
              let rightColumnIndex = layout.workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == rightColumnID })
        else { return }

        let clampedLeft = max(180, min(leftWidth, 2400))
        let clampedRight = max(180, min(rightWidth, 2400))
        layout.workspaces[workspaceIndex].columns[leftColumnIndex].preferredWidth = clampedLeft
        layout.workspaces[workspaceIndex].columns[rightColumnIndex].preferredWidth = clampedRight
        niriLayoutsBySession[sessionID] = layout
    }

    func niriSetColumnWidth(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        width: CGFloat
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let columnIndex = layout.workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == columnID })
        else { return }

        layout.workspaces[workspaceIndex].columns[columnIndex].preferredWidth = max(180, min(width, 2400))
        niriLayoutsBySession[sessionID] = layout
    }

    func niriSetItemHeights(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        upperItemID: UUID,
        upperHeight: CGFloat,
        lowerItemID: UUID,
        lowerHeight: CGFloat
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let columnIndex = layout.workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == columnID }),
              let upperItemIndex = layout.workspaces[workspaceIndex].columns[columnIndex].items.firstIndex(where: { $0.id == upperItemID }),
              let lowerItemIndex = layout.workspaces[workspaceIndex].columns[columnIndex].items.firstIndex(where: { $0.id == lowerItemID })
        else { return }

        let clampedUpper = max(120, min(upperHeight, 2400))
        let clampedLower = max(120, min(lowerHeight, 2400))
        layout.workspaces[workspaceIndex].columns[columnIndex].items[upperItemIndex].preferredHeight = clampedUpper
        layout.workspaces[workspaceIndex].columns[columnIndex].items[lowerItemIndex].preferredHeight = clampedLower
        niriLayoutsBySession[sessionID] = layout
    }

    func niriSetItemHeight(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        height: CGFloat
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let workspaceIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let columnIndex = layout.workspaces[workspaceIndex].columns.firstIndex(where: { $0.id == columnID }),
              let itemIndex = layout.workspaces[workspaceIndex].columns[columnIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }

        layout.workspaces[workspaceIndex].columns[columnIndex].items[itemIndex].preferredHeight = max(120, min(height, 2400))
        niriLayoutsBySession[sessionID] = layout
    }

    func moveNiriItem(
        sessionID: UUID,
        itemID: UUID,
        toWorkspaceID: UUID,
        toColumnID: UUID,
        targetIndex: Int? = nil
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let sourcePath = findNiriItemPath(layout: layout, itemID: itemID),
              let destinationWorkspaceIndex = layout.workspaces.firstIndex(where: { $0.id == toWorkspaceID }),
              let destinationColumnIndex = layout.workspaces[destinationWorkspaceIndex].columns.firstIndex(where: { $0.id == toColumnID })
        else { return }

        let item = layout.workspaces[sourcePath.workspaceIndex].columns[sourcePath.columnIndex].items.remove(at: sourcePath.itemIndex)
        let destinationItemsCount = layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].items.count
        let insertionIndex = max(0, min(targetIndex ?? destinationItemsCount, destinationItemsCount))
        layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].items.insert(item, at: insertionIndex)
        layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].focusedItemID = item.id

        layout.camera.activeWorkspaceID = toWorkspaceID
        layout.camera.activeColumnID = toColumnID
        layout.camera.focusedItemID = item.id
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
    }

    func moveNiriItemToWorkspace(sessionID: UUID, itemID: UUID, toWorkspaceID: UUID) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let sourcePath = findNiriItemPath(layout: layout, itemID: itemID),
              let destinationWorkspaceIndex = layout.workspaces.firstIndex(where: { $0.id == toWorkspaceID })
        else { return }

        let item = layout.workspaces[sourcePath.workspaceIndex].columns[sourcePath.columnIndex].items.remove(at: sourcePath.itemIndex)
        if let destinationColumnIndex = layout.workspaces[destinationWorkspaceIndex].columns.firstIndex(where: { !$0.items.isEmpty }) {
            layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].items.append(item)
            layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].focusedItemID = item.id
            layout.camera.activeColumnID = layout.workspaces[destinationWorkspaceIndex].columns[destinationColumnIndex].id
        } else {
            let column = makeNiriColumn(
                id: UUID(),
                items: [item],
                focusedItemID: item.id
            )
            layout.workspaces[destinationWorkspaceIndex].columns.append(column)
            layout.camera.activeColumnID = column.id
        }
        layout.camera.activeWorkspaceID = toWorkspaceID
        layout.camera.focusedItemID = item.id
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
    }

    /// Move an item to a brand-new column at a specific insertion index within a workspace.
    func moveNiriItemToNewColumn(
        sessionID: UUID,
        itemID: UUID,
        toWorkspaceID: UUID,
        atColumnIndex insertionIndex: Int
    ) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let sourcePath = findNiriItemPath(layout: layout, itemID: itemID),
              let destinationWorkspaceIndex = layout.workspaces.firstIndex(where: { $0.id == toWorkspaceID })
        else { return }

        let item = layout.workspaces[sourcePath.workspaceIndex].columns[sourcePath.columnIndex].items.remove(at: sourcePath.itemIndex)
        let newColumn = makeNiriColumn(
            id: UUID(),
            items: [item],
            focusedItemID: item.id
        )
        let safeIndex = max(0, min(insertionIndex, layout.workspaces[destinationWorkspaceIndex].columns.count))
        layout.workspaces[destinationWorkspaceIndex].columns.insert(newColumn, at: safeIndex)

        layout.camera.activeWorkspaceID = toWorkspaceID
        layout.camera.activeColumnID = newColumn.id
        layout.camera.focusedItemID = item.id
        normalizeNiriLayout(&layout)
        niriLayoutsBySession[sessionID] = layout
    }

    /// Swap two columns by index within a workspace.
    func swapNiriColumns(sessionID: UUID, workspaceID: UUID, fromIndex: Int, toIndex: Int) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let wsIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        let count = layout.workspaces[wsIndex].columns.count
        guard fromIndex >= 0, fromIndex < count, toIndex >= 0, toIndex < count, fromIndex != toIndex else { return }
        layout.workspaces[wsIndex].columns.swapAt(fromIndex, toIndex)
        niriLayoutsBySession[sessionID] = layout
    }

    func moveNiriColumn(sessionID: UUID, workspaceID: UUID, fromIndex: Int, toIndex: Int) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let wsIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        let count = layout.workspaces[wsIndex].columns.count
        guard fromIndex >= 0, fromIndex < count, toIndex >= 0, toIndex < count, fromIndex != toIndex else { return }
        let column = layout.workspaces[wsIndex].columns.remove(at: fromIndex)
        layout.workspaces[wsIndex].columns.insert(column, at: toIndex)
        niriLayoutsBySession[sessionID] = layout
    }

    func moveNiriItem(sessionID: UUID, workspaceID: UUID, columnID: UUID, fromIndex: Int, toIndex: Int) {
        ensureNiriLayout(for: sessionID)
        guard var layout = niriLayoutsBySession[sessionID],
              let wsIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let colIndex = layout.workspaces[wsIndex].columns.firstIndex(where: { $0.id == columnID })
        else { return }
        let count = layout.workspaces[wsIndex].columns[colIndex].items.count
        guard fromIndex >= 0, fromIndex < count, toIndex >= 0, toIndex < count, fromIndex != toIndex else { return }
        let item = layout.workspaces[wsIndex].columns[colIndex].items.remove(at: fromIndex)
        layout.workspaces[wsIndex].columns[colIndex].items.insert(item, at: toIndex)
        niriLayoutsBySession[sessionID] = layout
    }

}
