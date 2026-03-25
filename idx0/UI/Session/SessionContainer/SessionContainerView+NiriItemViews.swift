import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Preference key to report the tab divider row size up to the parent.
private struct NiriTabDividerSizeKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// A shape that traces the notebook-divider outline: tabs protruding from the top-left,
/// then the full-width tile body below.
private struct NiriNotebookDividerShape: Shape {
    var tabWidth: CGFloat
    var tabHeight: CGFloat
    var cornerRadius: CGFloat = 10
    var tabCornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let tw = min(tabWidth, rect.width)
        let th = tabHeight
        let cr = cornerRadius
        let tcr = tabCornerRadius

        var p = Path()

        // Start at top-left of tab area (with rounded corner)
        p.move(to: CGPoint(x: 0, y: tcr))
        p.addArc(
            center: CGPoint(x: tcr, y: tcr),
            radius: tcr, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )

        // Top edge of tabs
        p.addLine(to: CGPoint(x: tw - tcr, y: 0))
        p.addArc(
            center: CGPoint(x: tw - tcr, y: tcr),
            radius: tcr, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false
        )

        // Right edge of tab, down to body top
        p.addLine(to: CGPoint(x: tw, y: th))

        // Body top edge (from tab right edge to body right edge)
        p.addLine(to: CGPoint(x: rect.width - cr, y: th))
        p.addArc(
            center: CGPoint(x: rect.width - cr, y: th + cr),
            radius: cr, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false
        )

        // Right edge down
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - cr))
        p.addArc(
            center: CGPoint(x: rect.width - cr, y: rect.height - cr),
            radius: cr, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: cr, y: rect.height))
        p.addArc(
            center: CGPoint(x: cr, y: rect.height - cr),
            radius: cr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )

        // Left edge back up
        p.addLine(to: CGPoint(x: 0, y: tcr))

        p.closeSubpath()
        return p
    }
}

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
            itemID: item.id,
            item: item
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
        itemHeight: CGFloat,
        showHeader: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.showsTabBar {
                // Notebook-divider tabs: small tabs protruding above the tile body.
                // Canvas background is visible to the right of the last tab.
                niriTileTabDividers(
                    session: session,
                    item: item,
                    workspaceIndex: workspaceIndex,
                    columnIndex: columnIndex,
                    isFocused: isFocused
                )
                .fixedSize(horizontal: true, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: NiriTabDividerSizeKey.self, value: geo.size)
                    }
                )
            }

            // Main tile body
            VStack(spacing: 0) {
                if !item.showsTabBar, showHeader {
                    niriCanvasItemHeader(
                        sessionID: session.id,
                        workspaceIndex: workspaceIndex,
                        columnIndex: columnIndex,
                        item: item,
                        isFocused: isFocused
                    )
                }
                niriCanvasItemBodyContent(session: session, layout: layout, item: item)
                    .frame(maxHeight: .infinity)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: item.showsTabBar ? 0 : 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 10,
                    topTrailingRadius: 10
                )
            )
            .background(
                tc.surface0,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: item.showsTabBar ? 0 : 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 10,
                    topTrailingRadius: 10
                )
            )
        }
        .frame(width: itemWidth, height: itemHeight)
    }

    /// Notebook planner divider-style tabs. Each tab is a small protruding tab
    /// with rounded top corners. Canvas background is visible to the right.
    @ViewBuilder
    func niriTileTabDividers(
        session: Session,
        item: NiriLayoutItem,
        workspaceIndex: Int,
        columnIndex: Int,
        isFocused: Bool
    ) -> some View {
        let activeTabID = item.currentTerminalTabID
        HStack(spacing: 2) {
            ForEach(item.terminalTabIDs, id: \.self) { tabID in
                let isSelected = tabID == activeTabID
                let tabTitle = niriTabTitle(sessionID: session.id, tabID: tabID)
                Button {
                    sessionService.niriSwitchTabInTile(
                        sessionID: session.id,
                        itemID: item.id,
                        tabID: tabID
                    )
                } label: {
                    HStack(spacing: 4) {
                        Text(tabTitle)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if item.terminalTabIDs.count > 1 {
                            Button {
                                sessionService.niriCloseTabInTile(
                                    sessionID: session.id,
                                    itemID: item.id,
                                    tabID: tabID
                                )
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundStyle(tc.tertiaryText.opacity(0.7))
                                    .frame(width: 14, height: 14)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(isSelected ? tc.primaryText : tc.tertiaryText)
                    .background(
                        tc.surface0.opacity(isSelected ? 1.0 : 0.7),
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 8,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 8
                        )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // "+" button as a small divider tab
            Button {
                sessionService.niriAddTabToTile(
                    sessionID: session.id,
                    itemID: item.id
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tc.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(
                        tc.surface0.opacity(0.5),
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 8,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 8
                        )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Nothing to the right — canvas shows through
        }
    }

    func niriTabTitle(sessionID: UUID, tabID: UUID) -> String {
        let title = sessionService.tabState(sessionID: sessionID, tabID: tabID)?.title
        return niriTerminalTileTitle(from: title)
    }

    func niriCanvasItemHeader(
        sessionID: UUID,
        workspaceIndex: Int,
        columnIndex: Int,
        item: NiriLayoutItem,
        isFocused: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(niriItemTitle(sessionID: sessionID, item: item))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("w\(workspaceIndex + 1)·c\(columnIndex + 1)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(tc.tertiaryText)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(0)
            Spacer(minLength: 0)
            Button {
                sessionService.closeNiriItem(sessionID: sessionID, itemID: item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tc.tertiaryText)
                    .frame(width: 14, height: 14)
                    .idxHitTarget()
            }
            .buttonStyle(.plain)
            .opacity(isFocused ? 1 : 0.5)
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(tc.surface0.opacity(0.6))
        .clipped()
    }

    @ViewBuilder
    func niriCanvasItemBodyContent(
        session: Session,
        layout: NiriCanvasLayout,
        item: NiriLayoutItem
    ) -> some View {
        switch item.ref {
        case .terminal:
            let tabID = item.currentTerminalTabID ?? { if case .terminal(let id) = item.ref { return id }; return UUID() }()
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
        itemID: UUID,
        item: NiriLayoutItem
    ) -> some View {
        let isDragging = niriTileDrag?.itemID == itemID
        let dragTranslation = isDragging ? (niriTileDrag?.translation ?? .zero) : .zero

        return NiriStyledItemView(
            content: content,
            isOverviewOpen: layout.isOverviewOpen,
            isFocused: isFocused,
            hasTabBar: item.showsTabBar,
            accentColor: tc.accent,
            dividerColor: tc.divider,
            isDragging: isDragging,
            dragTranslation: dragTranslation
        )
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
        // Always show all edges and corners — like macOS window resizing.
        // Every tile can be resized from any edge or corner regardless of neighbors.
        return content
            // Edge resize handles — all 4 edges always available
            .overlay(alignment: .leading) {
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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
            // Corner resize handles — all 4 corners always available
            .overlay(alignment: .topLeading) {
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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
                if layout.isOverviewOpen {
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

/// Wrapper view that reads the tab divider size preference and draws the notebook-divider border.
private struct NiriStyledItemView<Content: View>: View {
    let content: Content
    let isOverviewOpen: Bool
    let isFocused: Bool
    let hasTabBar: Bool
    let accentColor: Color
    let dividerColor: Color
    let isDragging: Bool
    let dragTranslation: CGSize

    @State private var tabDividerSize: CGSize = .zero

    var body: some View {
        content
            .onPreferenceChange(NiriTabDividerSizeKey.self) { size in
                tabDividerSize = size
            }
            .overlay {
                if isOverviewOpen {
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
                if hasTabBar, tabDividerSize.width > 0 {
                    NiriNotebookDividerShape(
                        tabWidth: tabDividerSize.width,
                        tabHeight: tabDividerSize.height
                    )
                    .stroke(isFocused ? accentColor.opacity(0.4) : dividerColor.opacity(0.5), lineWidth: 1)
                    .animation(.easeOut(duration: 0.15), value: isFocused)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? accentColor.opacity(0.4) : dividerColor.opacity(0.5), lineWidth: 1)
                        .animation(.easeOut(duration: 0.15), value: isFocused)
                }
            }
            .shadow(color: isFocused ? accentColor.opacity(0.1) : .clear, radius: isFocused ? 4 : 0, x: 0, y: 0)
            .animation(.easeOut(duration: 0.15), value: isFocused)
            .offset(dragTranslation)
            .zIndex(isDragging ? 10 : 0)
            .scaleEffect(isDragging ? 1.05 : 1.0)
            .shadow(color: isDragging ? Color.black.opacity(0.35) : .clear, radius: isDragging ? 16 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.1), value: isDragging)
    }
}
