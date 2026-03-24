import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    @ViewBuilder
    func niriCanvasItemView(
        session: Session,
        layout: NiriCanvasLayout,
        workspace: NiriWorkspace,
        workspaceIndex: Int,
        column: NiriColumn,
        columnIndex: Int,
        item: NiriLayoutItem,
        metrics: NiriCanvasMetrics,
        itemHeight: CGFloat
    ) -> some View {
        let itemWidth = niriColumnWidth(column: column, metrics: metrics)
        let isFocused = layout.camera.focusedItemID == item.id
        let hasLeftColumnNeighbor = columnIndex > 0
        let hasRightColumnNeighbor = columnIndex + 1 < workspace.columns.count
        let itemIndex = column.items.firstIndex(where: { $0.id == item.id })
        let hasUpperItemNeighbor = itemIndex.map { $0 > 0 } ?? false
        let hasLowerItemNeighbor = itemIndex.map { $0 + 1 < column.items.count } ?? false
        let isLastItemInColumn = itemIndex.map { $0 == column.items.count - 1 } ?? false

        let core = niriCanvasItemCore(
            session: session,
            layout: layout,
            workspaceIndex: workspaceIndex,
            columnIndex: columnIndex,
            item: item,
            isFocused: isFocused,
            itemWidth: itemWidth,
            itemHeight: itemHeight
        )

        let styled = niriCanvasItemStyled(
            core,
            layout: layout,
            isFocused: isFocused,
            itemID: item.id
        )

        let interactive = niriCanvasItemInteractions(
            styled,
            session: session,
            layout: layout,
            workspace: workspace,
            column: column,
            item: item,
            metrics: metrics
        )

        niriCanvasItemResizeOverlays(
            interactive,
            session: session,
            layout: layout,
            workspace: workspace,
            column: column,
            item: item,
            metrics: metrics,
            hasLeftColumnNeighbor: hasLeftColumnNeighbor,
            hasRightColumnNeighbor: hasRightColumnNeighbor,
            hasUpperItemNeighbor: hasUpperItemNeighbor,
            hasLowerItemNeighbor: hasLowerItemNeighbor,
            isLastItemInColumn: isLastItemInColumn
        )
    }

    func niriCanvasItemCore(
        session: Session,
        layout: NiriCanvasLayout,
        workspaceIndex: Int,
        columnIndex: Int,
        item: NiriLayoutItem,
        isFocused: Bool,
        itemWidth: CGFloat,
        itemHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            niriCanvasItemHeader(
                sessionID: session.id,
                workspaceIndex: workspaceIndex,
                columnIndex: columnIndex,
                item: item,
                isFocused: isFocused
            )
            niriCanvasItemBodyContent(session: session, layout: layout, item: item)
        }
        .frame(width: itemWidth, height: itemHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(tc.surface0, in: RoundedRectangle(cornerRadius: 10))
    }

    func niriCanvasItemHeader(
        sessionID: UUID,
        workspaceIndex: Int,
        columnIndex: Int,
        item: NiriLayoutItem,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(niriItemTitle(sessionID: sessionID, item: item))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Text("w\(workspaceIndex + 1) · c\(columnIndex + 1)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(tc.tertiaryText)
            Spacer()
            Button {
                sessionService.closeNiriItem(sessionID: sessionID, itemID: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tc.tertiaryText)
                    .frame(width: 16, height: 16)
                    .idxHitTarget()
            }
            .buttonStyle(.plain)
            .opacity(isFocused ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tc.surface0.opacity(0.6))
    }

    @ViewBuilder
    func niriCanvasItemBodyContent(
        session: Session,
        layout: NiriCanvasLayout,
        item: NiriLayoutItem
    ) -> some View {
        switch item.ref {
        case .terminal(let tabID):
            if let tab = sessionService.tabState(sessionID: session.id, tabID: tabID) {
                let paneTree = tab.paneTree
                    ?? .terminal(id: tab.activeControllerID, controllerID: tab.activeControllerID)
                let focusedControllerID = tab.focusedPaneControllerID ?? tab.activeControllerID

                MultiPaneTerminalView(
                    paneTree: paneTree,
                    sessionID: session.id,
                    focusedControllerID: focusedControllerID,
                    controllerProvider: { controllerID in
                        sessionService.ensurePaneController(for: controllerID)
                    },
                    onFocus: { controllerID in
                        sessionService.niriSelectItem(sessionID: session.id, itemID: item.id)
                        sessionService.setFocusedPane(sessionID: session.id, controllerID: controllerID)
                        sessionService.markTerminalFocused(for: session.id)
                    },
                    isOverview: layout.isOverviewOpen
                )
            } else {
                niriUnavailableState(message: "Tab closed")
            }
        case .browser:
            if let browserController = sessionService.niriBrowserController(for: session.id, itemID: item.id) {
                OverviewSnapshotView(isOverview: layout.isOverviewOpen) {
                    NiriBrowserTile(session: session, controller: browserController)
                        .environmentObject(sessionService)
                }
            } else {
                niriUnavailableState(message: "Browser unavailable")
            }
        case .app(let appID):
            if let appTileView = sessionService.niriAppTileView(sessionID: session.id, itemID: item.id, appID: appID) {
                OverviewSnapshotView(isOverview: layout.isOverviewOpen) {
                    appTileView
                }
            } else if let descriptor = sessionService.niriAppDescriptor(for: appID) {
                niriUnavailableState(message: "\(descriptor.displayName) unavailable")
            } else {
                niriUnavailableState(message: "App unavailable")
            }
        }
    }

    func niriCanvasItemStyled<Content: View>(
        _ content: Content,
        layout: NiriCanvasLayout,
        isFocused: Bool,
        itemID: UUID
    ) -> some View {
        let isDragging = niriTileDrag?.itemID == itemID
        let dragTranslation = isDragging ? (niriTileDrag?.translation ?? .zero) : .zero

        return content
            .overlay {
                if layout.isOverviewOpen {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 26)
                            .allowsHitTesting(false)
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color.black.opacity(0.2))
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 0, bottomLeadingRadius: 10,
                                    bottomTrailingRadius: 10, topTrailingRadius: 0
                                )
                            )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? tc.accent.opacity(0.4) : tc.divider.opacity(0.5), lineWidth: 1)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
            .shadow(color: isFocused ? tc.accent.opacity(0.1) : .clear, radius: isFocused ? 4 : 0, x: 0, y: 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .offset(dragTranslation)
            .zIndex(isDragging ? 10 : 0)
            .scaleEffect(isDragging ? 1.05 : 1.0)
            .shadow(color: isDragging ? Color.black.opacity(0.35) : .clear, radius: isDragging ? 16 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.1), value: isDragging)
    }

    func niriCanvasItemInteractions<Content: View>(
        _ content: Content,
        session: Session,
        layout: NiriCanvasLayout,
        workspace: NiriWorkspace,
        column: NiriColumn,
        item: NiriLayoutItem,
        metrics: NiriCanvasMetrics
    ) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                layout.isOverviewOpen
                ? DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        niriHandleTileDragChanged(
                            sessionID: session.id,
                            workspaceID: workspace.id,
                            columnID: column.id,
                            itemID: item.id,
                            translation: value.translation,
                            metrics: metrics
                        )
                    }
                    .onEnded { _ in
                        niriHandleTileDragEnded()
                    }
                : nil
            )
            .onTapGesture {
                sessionService.niriSelectItem(sessionID: session.id, itemID: item.id)
                if layout.isOverviewOpen { return }
                switch item.ref {
                case .terminal:
                    sessionService.markTerminalFocused(for: session.id)
                case .browser:
                    sessionService.markBrowserFocused(for: session.id)
                case .app(let appID):
                    sessionService.markNiriAppFocused(for: session.id, appID: appID)
                }
            }
            .onHover { isHovering in
                guard !layout.isOverviewOpen || niriDraggedItemBySession[session.id] != nil else { return }
                niriHandleHoverActivation(
                    sessionID: session.id,
                    itemID: item.id,
                    isHovering: isHovering
                )
            }
    }

    func niriCanvasItemResizeOverlays<Content: View>(
        _ content: Content,
        session: Session,
        layout: NiriCanvasLayout,
        workspace: NiriWorkspace,
        column: NiriColumn,
        item: NiriLayoutItem,
        metrics: NiriCanvasMetrics,
        hasLeftColumnNeighbor: Bool,
        hasRightColumnNeighbor: Bool,
        hasUpperItemNeighbor: Bool,
        hasLowerItemNeighbor: Bool,
        isLastItemInColumn: Bool
    ) -> some View {
        let hasTopEdge = column.displayMode == .normal && hasUpperItemNeighbor
        let hasBottomEdge = column.displayMode == .normal && (hasLowerItemNeighbor || isLastItemInColumn)

        return content
            // Edge resize handles
            .overlay(alignment: .leading) {
                if layout.isOverviewOpen, hasLeftColumnNeighbor {
                    niriColumnResizeEdgeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        metrics: metrics,
                        edge: .leading
                    )
                }
            }
            .overlay(alignment: .trailing) {
                if layout.isOverviewOpen, hasRightColumnNeighbor {
                    niriColumnResizeEdgeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        metrics: metrics,
                        edge: .trailing
                    )
                }
            }
            .overlay(alignment: .top) {
                if layout.isOverviewOpen, hasTopEdge {
                    niriItemResizeEdgeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        edge: .top
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if layout.isOverviewOpen, hasBottomEdge {
                    niriItemResizeEdgeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        edge: .bottom
                    )
                }
            }
            // Corner resize handles — allow simultaneous H+V resize
            .overlay(alignment: .topLeading) {
                if layout.isOverviewOpen, hasLeftColumnNeighbor, hasTopEdge {
                    niriCornerResizeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        corner: .topLeading
                    )
                    .offset(x: -8, y: -8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if layout.isOverviewOpen, hasRightColumnNeighbor, hasTopEdge {
                    niriCornerResizeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        corner: .topTrailing
                    )
                    .offset(x: 8, y: -8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if layout.isOverviewOpen, hasLeftColumnNeighbor, hasBottomEdge {
                    niriCornerResizeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        corner: .bottomLeading
                    )
                    .offset(x: -8, y: 8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if layout.isOverviewOpen, hasRightColumnNeighbor, hasBottomEdge {
                    niriCornerResizeHotzone(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: item.id,
                        metrics: metrics,
                        corner: .bottomTrailing
                    )
                    .offset(x: 8, y: 8)
                }
            }
    }

    @ViewBuilder
    func niriUnavailableState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tc.tertiaryText)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tc.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func niriItemTitle(sessionID: UUID, item: NiriLayoutItem) -> String {
        switch item.ref {
        case .browser:
            return "Browser"
        case .app(let appID):
            return sessionService.niriAppDescriptor(for: appID)?.displayName ?? "App"
        case .terminal(let tabID):
            let title = sessionService.tabState(sessionID: sessionID, tabID: tabID)?.title
            return niriTerminalTileTitle(from: title)
        }
    }

    func niriTerminalTileTitle(from tabTitle: String?) -> String {
        guard let rawTitle = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else {
            return "Terminal"
        }

        if rawTitle.hasPrefix("Tab ") {
            let suffix = String(rawTitle.dropFirst(4))
            if !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) {
                return "Tile \(suffix)"
            }
        }

        return rawTitle
    }
}
