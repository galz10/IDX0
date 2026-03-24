import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriMetrics(containerSize: CGSize, isOverview: Bool) -> NiriCanvasMetrics {
        let scale: CGFloat = isOverview ? 0.55 : 1.0
        let width = max(420, min(containerSize.width * 0.72, 760)) * scale
        let height = max(240, min(containerSize.height * 0.62, 520)) * scale
        return NiriCanvasMetrics(
            tileWidth: width,
            tileHeight: height,
            columnSpacing: 18 * scale,
            itemSpacing: 18 * scale,
            workspaceSpacing: 54 * scale,
            headerHeight: 20,
            originX: max(20, containerSize.width * 0.5 - width * 0.5),
            originY: max(18, containerSize.height * 0.5 - height * 0.5),
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            canvasScale: scale
        )
    }

    func niriWorkspaceOffsetY(
        layout: NiriCanvasLayout,
        metrics: NiriCanvasMetrics,
        activeWorkspaceIndex: Int,
        workspaceIndex: Int
    ) -> CGFloat {
        guard activeWorkspaceIndex != workspaceIndex else { return 0 }
        if workspaceIndex > activeWorkspaceIndex {
            var offset: CGFloat = 0
            for index in activeWorkspaceIndex..<workspaceIndex {
                offset += niriWorkspaceStep(layout: layout, metrics: metrics, workspaceIndex: index)
            }
            return offset
        }

        var offset: CGFloat = 0
        for index in workspaceIndex..<activeWorkspaceIndex {
            offset -= niriWorkspaceStep(layout: layout, metrics: metrics, workspaceIndex: index)
        }
        return offset
    }

    func niriWorkspaceStep(
        layout: NiriCanvasLayout,
        metrics: NiriCanvasMetrics,
        workspaceIndex: Int
    ) -> CGFloat {
        guard workspaceIndex >= 0, workspaceIndex < layout.workspaces.count else {
            return metrics.tileHeight + metrics.workspaceSpacing
        }
        return niriWorkspaceHeight(
            workspace: layout.workspaces[workspaceIndex],
            metrics: metrics,
            isOverview: layout.isOverviewOpen
        ) + metrics.workspaceSpacing
    }

    func niriLeadingOffset(
        for workspace: NiriWorkspace,
        anchorColumnIndex: Int,
        metrics: NiriCanvasMetrics
    ) -> CGFloat {
        guard !workspace.columns.isEmpty else { return 0 }
        let clampedAnchor = min(max(anchorColumnIndex, 0), workspace.columns.count - 1)
        let safeAnchor = min(clampedAnchor, workspace.columns.count)
        var offset: CGFloat = 0
        for index in 0..<safeAnchor {
            offset += niriColumnWidth(column: workspace.columns[index], metrics: metrics)
            offset += metrics.columnSpacing
        }
        let anchorWidth = niriColumnWidth(column: workspace.columns[clampedAnchor], metrics: metrics)
        let centeringAdjustment = (metrics.tileWidth - anchorWidth) / 2
        return offset - centeringAdjustment
    }

    func niriWorkspaceHeight(workspace: NiriWorkspace, metrics: NiriCanvasMetrics, isOverview: Bool = false) -> CGFloat {
        guard !workspace.columns.isEmpty else {
            return metrics.headerHeight + metrics.tileHeight * 0.55 + 8
        }
        let tallestColumn = workspace.columns.map { column -> CGFloat in
            niriColumnContentHeight(column: column, metrics: metrics, isOverview: isOverview)
        }.max() ?? metrics.tileHeight
        return metrics.headerHeight + tallestColumn + 8
    }

    func niriColumnContentHeight(column: NiriColumn, metrics: NiriCanvasMetrics, isOverview: Bool = false) -> CGFloat {
        switch column.displayMode {
        case .normal:
            guard !column.items.isEmpty else { return metrics.tileHeight }
            let itemsHeight = column.items.reduce(CGFloat.zero) { partial, item in
                partial + (isOverview
                    ? niriOverviewItemHeight(column: column, item: item, metrics: metrics)
                    : niriItemHeight(item: item, metrics: metrics))
            }
            let spacing = CGFloat(max(column.items.count - 1, 0)) * metrics.itemSpacing
            return itemsHeight + spacing
        case .tabbed:
            let focusedID = column.focusedItemID ?? column.items.first?.id
            let focused = column.items.first(where: { $0.id == focusedID }) ?? column.items.first
            return niriItemHeight(item: focused, metrics: metrics) + 34
        }
    }

    func niriColumnMinWidth(metrics: NiriCanvasMetrics) -> CGFloat {
        max(260, metrics.tileWidth * 0.45)
    }

    func niriColumnMaxWidth(metrics: NiriCanvasMetrics) -> CGFloat {
        max(niriColumnMinWidth(metrics: metrics) + 80, metrics.tileWidth * 2.4)
    }

    func niriColumnWidth(column: NiriColumn, metrics: NiriCanvasMetrics) -> CGFloat {
        if let zoomedItemID = metrics.zoomedItemID,
           column.items.contains(where: { $0.id == zoomedItemID }) {
            return max(320, metrics.containerWidth - 12)
        }
        let minWidth = niriColumnMinWidth(metrics: metrics)
        let maxWidth = niriColumnMaxWidth(metrics: metrics)
        let preferredWidth = column.preferredWidth.map { $0 * metrics.canvasScale }
        return Swift.max(minWidth, Swift.min(maxWidth, preferredWidth ?? metrics.tileWidth))
    }

    func niriItemMinHeight(metrics: NiriCanvasMetrics) -> CGFloat {
        max(120, metrics.tileHeight * 0.32)
    }

    func niriItemMaxHeight(metrics: NiriCanvasMetrics) -> CGFloat {
        max(niriItemMinHeight(metrics: metrics) + 120, metrics.tileHeight * 4.8)
    }

    func niriItemHeight(item: NiriLayoutItem?, metrics: NiriCanvasMetrics) -> CGFloat {
        if let zoomedItemID = metrics.zoomedItemID, item?.id == zoomedItemID {
            return max(120, metrics.containerHeight - 12)
        }
        let minHeight = niriItemMinHeight(metrics: metrics)
        let maxHeight = niriItemMaxHeight(metrics: metrics)
        guard let preferred = item?.preferredHeight else {
            return Swift.max(minHeight, Swift.min(maxHeight, metrics.tileHeight))
        }
        return Swift.max(minHeight, Swift.min(maxHeight, preferred * metrics.canvasScale))
    }

    /// In overview mode, keep each tile's height stable so adding/removing
    /// stacked tiles doesn't cause sibling tile height jumps.
    func niriOverviewItemHeight(column: NiriColumn, item: NiriLayoutItem?, metrics: NiriCanvasMetrics) -> CGFloat {
        _ = column
        return niriItemHeight(item: item, metrics: metrics)
    }

    func niriActiveWorkspaceIndex(layout: NiriCanvasLayout) -> Int? {
        if let activeWorkspaceID = layout.camera.activeWorkspaceID,
           let index = layout.workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) {
            return index
        }
        return layout.workspaces.firstIndex(where: { !$0.columns.isEmpty }) ?? (layout.workspaces.isEmpty ? nil : 0)
    }

    func niriActiveColumnIndex(layout: NiriCanvasLayout, workspaceIndex: Int) -> Int? {
        guard workspaceIndex >= 0, workspaceIndex < layout.workspaces.count else { return nil }
        let workspace = layout.workspaces[workspaceIndex]
        if let activeColumnID = layout.camera.activeColumnID,
           let index = workspace.columns.firstIndex(where: { $0.id == activeColumnID }) {
            return index
        }
        return workspace.columns.isEmpty ? nil : 0
    }

    func niriAnchorColumnIndex(layout: NiriCanvasLayout, workspaceIndex: Int) -> Int {
        guard workspaceIndex >= 0, workspaceIndex < layout.workspaces.count else { return 0 }
        if let index = niriActiveColumnIndex(layout: layout, workspaceIndex: workspaceIndex) {
            return index
        }
        return 0
    }

}
