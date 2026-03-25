import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriWorkspaceView(
        session: Session,
        layout: NiriCanvasLayout,
        workspace: NiriWorkspace,
        workspaceIndex: Int,
        metrics: NiriCanvasMetrics
    ) -> some View {
        let anchorColumn = niriAnchorColumnIndex(
            layout: layout,
            workspaceIndex: workspaceIndex
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("Workspace \(workspaceIndex + 1)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tc.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: metrics.headerHeight, alignment: .leading)

            if workspace.columns.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tc.surface0.opacity(0.45))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.rectangle.on.rectangle")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(tc.tertiaryText)
                            Text("Drop here or add a terminal")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tc.tertiaryText)
                        }
                    }
                    .frame(width: metrics.tileWidth, height: metrics.tileHeight * 0.55)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(workspace.columns.enumerated()), id: \.element.id) { columnIndex, column in
                        // Drop zone before this column (place as new column to its left)
                        if layout.isOverviewOpen, niriDraggedItemBySession[session.id] != nil {
                            niriInterColumnDropZone(
                                sessionID: session.id,
                                workspaceID: workspace.id,
                                insertionIndex: columnIndex,
                                height: niriColumnContentHeight(column: column, metrics: metrics, isOverview: true),
                                metrics: metrics
                            )
                        }

                        niriColumnView(
                            session: session,
                            layout: layout,
                            workspace: workspace,
                            workspaceIndex: workspaceIndex,
                            column: column,
                            columnIndex: columnIndex,
                            metrics: metrics
                        )
                        .zIndex(niriTileDrag?.columnID == column.id && column.items.contains(where: { $0.id == niriTileDrag?.itemID }) ? 100 : 0)

                        if columnIndex < workspace.columns.count - 1 {
                            if layout.isOverviewOpen {
                                niriColumnResizeHandle(
                                    sessionID: session.id,
                                    workspace: workspace,
                                    leftColumn: column,
                                    rightColumn: workspace.columns[columnIndex + 1],
                                    metrics: metrics
                                )
                            } else {
                                Spacer()
                                    .frame(width: 5)
                            }
                        }
                    }

                    // Trailing drop zone after the last column
                    if layout.isOverviewOpen, niriDraggedItemBySession[session.id] != nil {
                        niriInterColumnDropZone(
                            sessionID: session.id,
                            workspaceID: workspace.id,
                            insertionIndex: workspace.columns.count,
                            height: metrics.tileHeight,
                            metrics: metrics
                        )
                    }
                }
                .animation(.spring(duration: 0.55, bounce: 0.12), value: workspace.columns.map(\.id))
                .offset(
                    x: -niriLeadingOffset(
                        for: workspace,
                        anchorColumnIndex: anchorColumn,
                        metrics: metrics
                    ),
                    y: 0
                )
            }
        }
    }

    @ViewBuilder
    func niriColumnView(
        session: Session,
        layout: NiriCanvasLayout,
        workspace: NiriWorkspace,
        workspaceIndex: Int,
        column: NiriColumn,
        columnIndex: Int,
        metrics: NiriCanvasMetrics
    ) -> some View {
        let columnWidth = niriColumnWidth(column: column, metrics: metrics)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(column.items.enumerated()), id: \.element.id) { itemIndex, item in
                let itemHeight = layout.isOverviewOpen
                    ? niriOverviewItemHeight(column: column, item: item, metrics: metrics)
                    : niriItemHeight(item: item, metrics: metrics)
                niriCanvasItemView(
                    session: session,
                    layout: layout,
                    workspace: workspace,
                    workspaceIndex: workspaceIndex,
                    column: column,
                    columnIndex: columnIndex,
                    item: item,
                    metrics: metrics,
                    itemHeight: itemHeight
                )

                if itemIndex < column.items.count - 1 {
                    if layout.isOverviewOpen {
                        niriItemResizeHandle(
                            sessionID: session.id,
                            workspace: workspace,
                            column: column,
                            upperItem: item,
                            lowerItem: column.items[itemIndex + 1],
                            metrics: metrics
                        )
                    } else {
                        Spacer()
                            .frame(height: 5)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.12), value: column.items.map(\.id))
        .frame(width: columnWidth)
    }
}
