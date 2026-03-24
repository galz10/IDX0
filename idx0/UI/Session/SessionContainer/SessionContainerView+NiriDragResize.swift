import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriColumnResizeEdgeHotzone(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        metrics: NiriCanvasMetrics,
        edge: NiriEdgeAlignment
    ) -> some View {
        let hitWidth: CGFloat = 14
        return NiriResizeEdgeHandle(
            axis: .horizontal,
            onBegin: {
                niriStartColumnEdgeResizeVisualizer(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    edge: edge
                )
            },
            onDelta: { delta in
                let adjustedDelta = edge == .leading ? -delta : delta
                niriApplyColumnResizeDelta(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    delta: adjustedDelta,
                    metrics: metrics
                )
            },
            onEnd: {
                niriClearResizeVisualizer(sessionID: sessionID)
            }
        )
        .frame(width: hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .offset(x: edge == .leading ? -hitWidth / 2 : hitWidth / 2)
    }

    func niriItemResizeEdgeHotzone(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        metrics: NiriCanvasMetrics,
        edge: NiriVerticalEdgeAlignment
    ) -> some View {
        let hitHeight: CGFloat = 14
        return NiriResizeEdgeHandle(
            axis: .vertical,
            onBegin: {
                niriStartItemEdgeResizeVisualizer(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    itemID: itemID,
                    edge: edge
                )
            },
            onDelta: { delta in
                let adjustedDelta = edge == .top ? delta : -delta
                niriApplyItemResizeDelta(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    itemID: itemID,
                    delta: adjustedDelta,
                    metrics: metrics
                )
            },
            onEnd: {
                niriClearResizeVisualizer(sessionID: sessionID)
            }
        )
        .frame(height: hitHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .offset(y: edge == .top ? -hitHeight / 2 : hitHeight / 2)
    }

    func niriCornerResizeHotzone(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        metrics: NiriCanvasMetrics,
        corner: NiriCornerPosition
    ) -> some View {
        let hitSize: CGFloat = 16
        return NiriResizeCornerHandle(
            corner: corner,
            onBegin: {
                niriStartCornerResizeVisualizer(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    itemID: itemID,
                    corner: corner
                )
            },
            onDelta: { deltaX, deltaY in
                let columnDelta: CGFloat
                switch corner {
                case .topLeading, .bottomLeading:
                    columnDelta = -deltaX
                case .topTrailing, .bottomTrailing:
                    columnDelta = deltaX
                }
                let itemDelta: CGFloat
                switch corner {
                case .topLeading, .topTrailing:
                    itemDelta = deltaY   // NSView Y is flipped: dragging up = negative Y = shrink
                case .bottomLeading, .bottomTrailing:
                    itemDelta = -deltaY  // dragging down = negative Y in NSView = grow
                }
                niriApplyColumnResizeDelta(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    delta: columnDelta,
                    metrics: metrics
                )
                niriApplyItemResizeDelta(
                    sessionID: sessionID,
                    workspaceID: workspaceID,
                    columnID: columnID,
                    itemID: itemID,
                    delta: itemDelta,
                    metrics: metrics
                )
            },
            onEnd: {
                niriClearResizeVisualizer(sessionID: sessionID)
            }
        )
        .frame(width: hitSize, height: hitSize)
        .contentShape(Rectangle())
    }

    func niriStartCornerResizeVisualizer(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        corner: NiriCornerPosition
    ) {
        // Use column visualizer since corner affects both width and height
        let layout = sessionService.niriLayout(for: sessionID)
        guard let workspace = layout.workspaces.first(where: { $0.id == workspaceID }),
              let columnIndex = workspace.columns.firstIndex(where: { $0.id == columnID })
        else { return }

        let neighborColumnID: UUID?
        switch corner {
        case .topLeading, .bottomLeading:
            neighborColumnID = columnIndex > 0 ? workspace.columns[columnIndex - 1].id : nil
        case .topTrailing, .bottomTrailing:
            neighborColumnID = columnIndex + 1 < workspace.columns.count ? workspace.columns[columnIndex + 1].id : nil
        }

        niriSetResizeVisualizer(
            sessionID: sessionID,
            state: NiriResizeVisualizerState(
                kind: .column,
                workspaceID: workspaceID,
                primaryColumnID: columnID,
                secondaryColumnID: neighborColumnID,
                primaryItemID: itemID,
                secondaryItemID: nil
            )
        )
    }

    @ViewBuilder
    func niriInterColumnDropZone(
        sessionID: UUID,
        workspaceID: UUID,
        insertionIndex: Int,
        height: CGFloat,
        metrics: NiriCanvasMetrics
    ) -> some View {
        let target = NiriDropInsertionTarget(
            workspaceID: workspaceID,
            columnInsertionIndex: insertionIndex
        )
        let isTargeted = niriDropInsertionTarget == target
        let baseWidth: CGFloat = metrics.columnSpacing + 28
        let dropWidth: CGFloat = isTargeted ? baseWidth + 24 : baseWidth

        ZStack {
            // Visible insertion line
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isTargeted ? tc.accent.opacity(0.5) : tc.divider.opacity(0.25))
                .frame(width: isTargeted ? 4 : 2, height: height * 0.7)

            // Full-size hit target (invisible)
            Color.clear
                .frame(width: dropWidth, height: height)
                .contentShape(Rectangle())
        }
        .frame(width: dropWidth, height: height)
        .onDrop(of: [UTType.text.identifier], isTargeted: Binding(
            get: { niriDropInsertionTarget == target },
            set: { targeted in
                if targeted {
                    niriDropInsertionTarget = target
                } else if niriDropInsertionTarget == target {
                    niriDropInsertionTarget = nil
                }
            }
        )) { providers in
            niriDropInsertionTarget = nil
            return niriHandleDropAsNewColumn(
                providers: providers,
                sessionID: sessionID,
                toWorkspaceID: workspaceID,
                atColumnIndex: insertionIndex
            )
        }
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }

    func niriHandleDropAsNewColumn(
        providers: [NSItemProvider],
        sessionID: UUID,
        toWorkspaceID: UUID,
        atColumnIndex: Int
    ) -> Bool {
        guard sessionService.niriLayout(for: sessionID).isOverviewOpen else { return false }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let stringObject = object as? NSString else { return }
            guard let itemID = UUID(uuidString: String(stringObject)) else { return }
            DispatchQueue.main.async {
                sessionService.moveNiriItemToNewColumn(
                    sessionID: sessionID,
                    itemID: itemID,
                    toWorkspaceID: toWorkspaceID,
                    atColumnIndex: atColumnIndex
                )
                niriDraggedItemBySession[sessionID] = nil
                niriCancelEdgeAutoScroll(sessionID: sessionID)
            }
        }
        return true
    }

    // MARK: - Custom tile drag-to-reorder

    func niriHandleTileDragChanged(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        translation: CGSize,
        metrics: NiriCanvasMetrics
    ) {
        // Read the live layout to get current indices
        let layout = sessionService.niriLayout(for: sessionID)
        guard let wsIndex = layout.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let workspace = layout.workspaces[wsIndex]

        // Find the current column and item indices from live data
        guard let liveColumnIndex = workspace.columns.firstIndex(where: { $0.id == columnID }) else { return }
        let liveColumn = workspace.columns[liveColumnIndex]
        let liveItemIndex = liveColumn.items.firstIndex(where: { $0.id == itemID }) ?? 0

        // Initialize drag state on first call
        if niriTileDrag == nil || niriTileDrag!.itemID != itemID {
            // Focus the dragged item so the layout tracks it correctly
            sessionService.niriSelectItem(sessionID: sessionID, itemID: itemID)

            niriTileDrag = NiriTileDragState(
                sessionID: sessionID,
                workspaceID: workspaceID,
                columnID: columnID,
                itemID: itemID,
                originColumnIndex: liveColumnIndex,
                originItemIndex: liveItemIndex,
                currentColumnIndex: liveColumnIndex,
                currentItemIndex: liveItemIndex,
                translation: translation
            )
        } else {
            niriTileDrag?.translation = translation
        }

        guard var drag = niriTileDrag else { return }

        // Lock axis based on initial drag direction
        if drag.axis == .undecided {
            let absX = abs(translation.width)
            let absY = abs(translation.height)
            if absX > 12 || absY > 12 {
                drag.axis = liveColumn.items.count <= 1 ? .horizontal
                    : absX > absY ? .horizontal : .vertical
                niriTileDrag = drag
            } else {
                return
            }
        }

        let reorderSpring = Animation.spring(duration: 0.55, bounce: 0.12)

        if drag.axis == .horizontal {
            let columnStep = metrics.tileWidth + metrics.columnSpacing
            let edgeOffset: CGFloat = translation.width > 0 ? metrics.tileWidth * 0.6 : -metrics.tileWidth * 0.6
            let columnSlotsFromOrigin = ((translation.width + edgeOffset) / columnStep).rounded()
            let targetColumnIndex = max(0, min(workspace.columns.count - 1,
                drag.originColumnIndex + Int(columnSlotsFromOrigin)))

            if targetColumnIndex != drag.currentColumnIndex {
                withAnimation(reorderSpring) {
                    sessionService.moveNiriColumn(
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        fromIndex: drag.currentColumnIndex,
                        toIndex: targetColumnIndex
                    )
                }
                drag.currentColumnIndex = targetColumnIndex
                niriTileDrag = drag
            }
        } else if drag.axis == .vertical, liveColumn.items.count > 1 {
            let itemHeight = niriOverviewItemHeight(
                column: liveColumn,
                item: liveColumn.items.first(where: { $0.id == itemID }),
                metrics: metrics
            )
            let itemStep = itemHeight + metrics.itemSpacing
            // When dragging down, measure from the bottom edge of the tile;
            // when dragging up, measure from the top edge.
            let edgeOffset: CGFloat = translation.height > 0 ? itemHeight * 0.75 : -itemHeight * 0.75
            let itemSlotsFromOrigin = ((translation.height + edgeOffset) / itemStep).rounded()
            let targetItemIndex = max(0, min(liveColumn.items.count - 1,
                drag.originItemIndex + Int(itemSlotsFromOrigin)))

            if targetItemIndex != drag.currentItemIndex {
                withAnimation(reorderSpring) {
                    sessionService.moveNiriItem(
                        sessionID: sessionID,
                        workspaceID: workspaceID,
                        columnID: columnID,
                        fromIndex: drag.currentItemIndex,
                        toIndex: targetItemIndex
                    )
                }
                drag.currentItemIndex = targetItemIndex
                niriTileDrag = drag
            }
        }
    }

    func niriHandleTileDragEnded() {
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
            niriTileDrag = nil
        }
    }

    func niriHandleDrop(
        providers: [NSItemProvider],
        sessionID: UUID,
        toWorkspaceID: UUID,
        toColumnID: UUID?
    ) -> Bool {
        guard sessionService.niriLayout(for: sessionID).isOverviewOpen else {
            return false
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let stringObject = object as? NSString else { return }
            let string = String(stringObject)
            guard let itemID = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                if let toColumnID {
                    sessionService.moveNiriItem(
                        sessionID: sessionID,
                        itemID: itemID,
                        toWorkspaceID: toWorkspaceID,
                        toColumnID: toColumnID
                    )
                } else {
                    sessionService.moveNiriItemToWorkspace(
                        sessionID: sessionID,
                        itemID: itemID,
                        toWorkspaceID: toWorkspaceID
                    )
                }
                niriDraggedItemBySession[sessionID] = nil
                niriCancelEdgeAutoScroll(sessionID: sessionID)
            }
        }
        return true
    }

    @ViewBuilder
    func niriColumnResizeHandle(
        sessionID: UUID,
        workspace: NiriWorkspace,
        leftColumn: NiriColumn,
        rightColumn: NiriColumn,
        metrics: NiriCanvasMetrics
    ) -> some View {
        let handleHeight = max(
            niriColumnContentHeight(column: leftColumn, metrics: metrics, isOverview: true),
            niriColumnContentHeight(column: rightColumn, metrics: metrics, isOverview: true)
        )

        ZStack {
            Rectangle()
                .fill(Color.clear)
                .overlay {
                    Rectangle()
                        .fill(tc.divider.opacity(0.3))
                        .frame(width: 1)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .fill(tc.divider.opacity(0.95))
                        .frame(width: 3, height: max(24, min(56, handleHeight * 0.18)))
                }

            NiriResizeEdgeHandle(
                axis: .horizontal,
                onBegin: {
                    niriSetColumnResizeVisualizer(
                        sessionID: sessionID,
                        workspaceID: workspace.id,
                        leftColumnID: leftColumn.id,
                        rightColumnID: rightColumn.id
                    )
                },
                onDelta: { delta in
                    niriApplyColumnResizeDelta(
                        sessionID: sessionID,
                        workspaceID: workspace.id,
                        columnID: leftColumn.id,
                        delta: delta,
                        metrics: metrics
                    )
                },
                onEnd: {
                    niriClearResizeVisualizer(sessionID: sessionID)
                }
            )
        }
        .frame(width: metrics.columnSpacing, height: handleHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func niriItemResizeHandle(
        sessionID: UUID,
        workspace: NiriWorkspace,
        column: NiriColumn,
        upperItem: NiriLayoutItem,
        lowerItem: NiriLayoutItem,
        metrics: NiriCanvasMetrics
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .overlay {
                    Capsule(style: .continuous)
                        .fill(tc.divider.opacity(0.95))
                        .frame(width: 44, height: 3)
                }

            NiriResizeEdgeHandle(
                axis: .vertical,
                onBegin: {
                    niriSetItemResizeVisualizer(
                        sessionID: sessionID,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        primaryItemID: upperItem.id,
                        secondaryItemID: lowerItem.id
                    )
                },
                onDelta: { delta in
                    // NSView Y is flipped: positive delta = mouse moved up = shrink upper item
                    // We want dragging down to grow the upper item, so negate
                    niriApplyItemResizeDelta(
                        sessionID: sessionID,
                        workspaceID: workspace.id,
                        columnID: column.id,
                        itemID: upperItem.id,
                        delta: -delta,
                        metrics: metrics
                    )
                },
                onEnd: {
                    niriClearResizeVisualizer(sessionID: sessionID)
                }
            )
        }
        .frame(width: niriColumnWidth(column: column, metrics: metrics), height: metrics.itemSpacing)
        .contentShape(Rectangle())
    }

    func niriApplyColumnResizeDelta(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        delta: CGFloat,
        metrics: NiriCanvasMetrics
    ) {
        guard abs(delta) > 0.01 else { return }
        let layout = sessionService.niriLayout(for: sessionID)
        guard layout.isOverviewOpen else { return }
        guard let workspace = layout.workspaces.first(where: { $0.id == workspaceID }),
              let column = workspace.columns.first(where: { $0.id == columnID })
        else { return }

        let current = niriColumnWidth(column: column, metrics: metrics)
        let minWidth = niriColumnMinWidth(metrics: metrics)
        let maxWidth = niriColumnMaxWidth(metrics: metrics)
        let target = max(minWidth, min(maxWidth, current + delta))
        let canonicalTarget = target / max(metrics.canvasScale, 0.0001)

        guard abs(target - current) > 0.01 else { return }
        sessionService.niriSetColumnWidth(
            sessionID: sessionID,
            workspaceID: workspaceID,
            columnID: columnID,
            width: canonicalTarget
        )
    }

    func niriApplyItemResizeDelta(
        sessionID: UUID,
        workspaceID: UUID,
        columnID: UUID,
        itemID: UUID,
        delta: CGFloat,
        metrics: NiriCanvasMetrics
    ) {
        guard abs(delta) > 0.01 else { return }
        let layout = sessionService.niriLayout(for: sessionID)
        guard layout.isOverviewOpen else { return }
        guard let workspace = layout.workspaces.first(where: { $0.id == workspaceID }),
              let column = workspace.columns.first(where: { $0.id == columnID }),
              let item = column.items.first(where: { $0.id == itemID })
        else { return }

        let current = niriItemHeight(item: item, metrics: metrics)
        let minHeight = niriItemMinHeight(metrics: metrics)
        let maxHeight = niriItemMaxHeight(metrics: metrics)
        let target = max(minHeight, min(maxHeight, current + delta))
        let canonicalTarget = target / max(metrics.canvasScale, 0.0001)

        guard abs(target - current) > 0.01 else { return }
        sessionService.niriSetItemHeight(
            sessionID: sessionID,
            workspaceID: workspaceID,
            columnID: columnID,
            itemID: itemID,
            height: canonicalTarget
        )
    }

}
