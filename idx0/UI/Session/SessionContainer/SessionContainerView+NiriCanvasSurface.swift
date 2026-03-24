import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriCanvasSurface(session: Session) -> some View {
        let layout = sessionService.niriLayout(for: session.id)
        let runtime = niriRuntimeBySession[session.id] ?? NiriCanvasRuntimeState()

        return niriCanvasSurfaceBody(session: session, layout: layout, runtime: runtime)
        .overlay {
            // Invisible dismiss layer when spotlight is open
            if niriQuickAddMenuPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.2, bounce: 0.1)) {
                            niriQuickAddMenuPresented = false
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            niriCanvasQuickAddButton(sessionID: session.id)
                .padding(.top, 38)
                .padding(.leading, 10)
        }
        .animation(.spring(duration: 0.25, bounce: 0.1), value: niriQuickAddMenuPresented)
        .overlay(alignment: .topTrailing) {
            if let visualizer = niriActiveResizeVisualizer(
                sessionID: session.id,
                layout: layout
            ) {
                let previewContainer = runtime.lastContainerSize == .zero
                    ? CGSize(width: 1400, height: 860)
                    : runtime.lastContainerSize
                let previewMetrics = niriMetrics(
                    containerSize: previewContainer,
                    isOverview: false
                )
                niriResizeVisualizerHUD(
                    state: visualizer,
                    layout: layout,
                    metrics: previewMetrics
                )
                    .padding(.top, 72)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            sessionService.ensureNiriLayoutState(for: session.id)
            if niriRuntimeBySession[session.id] == nil {
                niriRuntimeBySession[session.id] = NiriCanvasRuntimeState()
            }
            if sessionService.selectedSessionID == session.id {
                _ = sessionService.launchFocusedNiriTerminalIfVisible(
                    sessionID: session.id,
                    reason: .selectedSessionVisible
                )
            }
        }
        .onReceive(coordinator.$niriQuickAddRequestSessionID) { requestedSessionID in
            guard requestedSessionID == session.id else { return }
            withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                niriQuickAddMenuPresented = true
            }
            coordinator.niriQuickAddRequestSessionID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .niriSpotlightDismissRequested)) { _ in
            guard niriQuickAddMenuPresented else { return }
            withAnimation(.spring(duration: 0.2, bounce: 0.1)) {
                niriQuickAddMenuPresented = false
            }
        }
        .onDisappear {
            niriCancelEdgeAutoScroll(sessionID: session.id)
            niriCancelHoverActivation(sessionID: session.id)
            niriClearResizeVisualizer(sessionID: session.id)
            sessionService.controllerBecameHidden(sessionID: session.id)
            niriQuickAddMenuPresented = false
        }
        .onChange(of: layout.camera.activeColumnID) { _, _ in
            niriAnimateCameraToFocusedColumn(sessionID: session.id)
        }
        .onChange(of: layout.camera.focusedItemID) { _, _ in
            niriAnimateCameraToFocusedColumn(sessionID: session.id)
            guard sessionService.selectedSessionID == session.id else { return }
            guard !layout.isOverviewOpen else { return }

            if let focusedItemID = layout.camera.focusedItemID,
               let path = sessionService.findNiriItemPath(layout: layout, itemID: focusedItemID),
               case .terminal(let focusedTabID) =
                   layout.workspaces[path.workspaceIndex].columns[path.columnIndex].items[path.itemIndex].ref,
               sessionService.selectedTabID(for: session.id) == focusedTabID {
                return
            }

            _ = sessionService.launchFocusedNiriTerminalIfVisible(sessionID: session.id)
        }
        .onChange(of: layout.isOverviewOpen) { _, isOverviewOpen in
            if !isOverviewOpen {
                niriClearResizeVisualizer(sessionID: session.id)
                if sessionService.selectedSessionID == session.id {
                    _ = sessionService.launchFocusedNiriTerminalIfVisible(
                        sessionID: session.id,
                        reason: .selectedSessionVisible
                    )
                }
            }
        }
        .onChange(of: layout.camera.activeWorkspaceID) { _, newID in
            niriAnimateCameraToFocusedColumn(sessionID: session.id)
            // Show workspace switch OSD briefly
            if let newID, let idx = layout.workspaces.firstIndex(where: { $0.id == newID }) {
                niriShowWorkspaceOSD("Workspace \(idx + 1)")
            }
        }
        .onChange(of: sessionService.settings.niri.resizeCameraVisualizerEnabled) { _, enabled in
            if !enabled {
                niriClearResizeVisualizer(sessionID: session.id)
            }
        }
    }

    @ViewBuilder
    func niriCanvasSurfaceBody(
        session: Session,
        layout: NiriCanvasLayout,
        runtime: NiriCanvasRuntimeState
    ) -> some View {
        VStack(spacing: 0) {
            niriCanvasToolbar(sessionID: session.id, layout: layout)
            GeometryReader { proxy in
                niriCanvasGeometryView(
                    session: session,
                    layout: layout,
                    runtime: runtime,
                    proxy: proxy
                )
            }
        }
    }

    func niriCanvasGeometryView(
        session: Session,
        layout: NiriCanvasLayout,
        runtime: NiriCanvasRuntimeState,
        proxy: GeometryProxy
    ) -> some View {
        var metrics = niriMetrics(
            containerSize: proxy.size,
            isOverview: layout.isOverviewOpen
        )
        let activeWorkspaceIndex = niriActiveWorkspaceIndex(layout: layout) ?? 0
        let zoomedItemID = sessionService.niriFocusedTileZoomItemID(for: session.id)
        metrics.zoomedItemID = zoomedItemID

        return niriCanvasKeyHandling(
            niriCanvasViewportLayer(
                session: session,
                layout: layout,
                runtime: runtime,
                metrics: metrics,
                activeWorkspaceIndex: activeWorkspaceIndex,
                proxySize: proxy.size
            )
            .clipped()
            .onAppear {
                if niriRuntimeBySession[session.id] != nil {
                    niriRuntimeBySession[session.id]?.lastContainerSize = proxy.size
                } else {
                    var runtime = NiriCanvasRuntimeState()
                    runtime.lastContainerSize = proxy.size
                    niriRuntimeBySession[session.id] = runtime
                }
            }
            .onChange(of: proxy.size) { _, newSize in
                niriRuntimeBySession[session.id]?.lastContainerSize = newSize
            },
            sessionID: session.id,
            isOverviewOpen: layout.isOverviewOpen,
            isFocusedTileZoomed: zoomedItemID != nil
        )
        .animation(.spring(duration: 0.35, bounce: 0.08), value: layout.isOverviewOpen)
        .animation(.spring(duration: 0.25, bounce: 0), value: layout.camera.focusedItemID)
        .animation(.spring(duration: 0.25, bounce: 0), value: layout.camera.activeColumnID)
        .animation(.spring(duration: 0.25, bounce: 0), value: layout.camera.activeWorkspaceID)
        .animation(.spring(duration: 0.25, bounce: 0), value: zoomedItemID)
        .overlay {
            if let osdText = niriWorkspaceSwitchOSD {
                Text(osdText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(tc.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: niriWorkspaceSwitchOSD)
    }

    @ViewBuilder
    func niriCanvasViewportLayer(
        session: Session,
        layout: NiriCanvasLayout,
        runtime: NiriCanvasRuntimeState,
        metrics: NiriCanvasMetrics,
        activeWorkspaceIndex: Int,
        proxySize: CGSize
    ) -> some View {
        let centeringY = niriFocusedItemCenteringY(
            layout: layout,
            metrics: metrics,
            containerSize: proxySize
        )
        let cameraOffsetX = runtime.cameraOffset.width + runtime.transientOffset.width
        let cameraOffsetY = runtime.cameraOffset.height + runtime.transientOffset.height

        ZStack(alignment: .topLeading) {
            if metrics.zoomedItemID != nil {
                tc.windowBackground
            } else {
                NiriDotGridBackground(
                    offsetX: cameraOffsetX,
                    offsetY: centeringY + cameraOffsetY
                )
                .overlay {
                    niriCanvasPanCapture(
                        sessionID: session.id,
                        layout: layout,
                        metrics: metrics
                    )
                }
            }

            ForEach(Array(layout.workspaces.enumerated()), id: \.element.id) { workspaceIndex, workspace in
                let workspaceY = niriWorkspaceOffsetY(
                    layout: layout,
                    metrics: metrics,
                    activeWorkspaceIndex: activeWorkspaceIndex,
                    workspaceIndex: workspaceIndex
                ) + centeringY + cameraOffsetY
                let shouldRenderLiveWorkspace = niriShouldRenderLiveWorkspace(
                    layout: layout,
                    activeWorkspaceIndex: activeWorkspaceIndex,
                    workspaceIndex: workspaceIndex
                )

                Group {
                    if shouldRenderLiveWorkspace {
                        niriWorkspaceView(
                            session: session,
                            layout: layout,
                            workspace: workspace,
                            workspaceIndex: workspaceIndex,
                            metrics: metrics
                        )
                    } else {
                        niriWorkspacePlaceholderView(
                            workspace: workspace,
                            workspaceIndex: workspaceIndex,
                            metrics: metrics
                        )
                    }
                }
                .offset(
                    x: metrics.originX + cameraOffsetX,
                    y: metrics.originY + workspaceY
                )
                .onDrop(of: [UTType.text.identifier], isTargeted: nil) { providers in
                    guard layout.isOverviewOpen else { return false }
                    return niriHandleDrop(
                        providers: providers,
                        sessionID: session.id,
                        toWorkspaceID: workspace.id,
                        toColumnID: nil
                    )
                }
            }

            niriEdgeAutoScrollOverlay(
                sessionID: session.id,
                isOverviewOpen: layout.isOverviewOpen
            )
        }
    }

    func niriShouldRenderLiveWorkspace(
        layout: NiriCanvasLayout,
        activeWorkspaceIndex: Int,
        workspaceIndex: Int
    ) -> Bool {
        if layout.isOverviewOpen {
            return true
        }
        return abs(workspaceIndex - activeWorkspaceIndex) <= 1
    }

    func niriWorkspacePlaceholderView(
        workspace: NiriWorkspace,
        workspaceIndex: Int,
        metrics: NiriCanvasMetrics
    ) -> some View {
        let columnCount = workspace.columns.count
        let itemCount = workspace.columns.reduce(into: 0) { partialResult, column in
            partialResult += column.items.count
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Workspace \(workspaceIndex + 1)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tc.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: metrics.headerHeight, alignment: .leading)

            RoundedRectangle(cornerRadius: 12)
                .fill(tc.surface0.opacity(0.35))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(tc.tertiaryText)
                        Text("\(columnCount) column\(columnCount == 1 ? "" : "s") · \(itemCount) item\(itemCount == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tc.tertiaryText)
                    }
                }
                .frame(width: metrics.tileWidth, height: metrics.tileHeight * 0.5)
        }
    }

    func niriCanvasPanCapture(
        sessionID: UUID,
        layout: NiriCanvasLayout,
        metrics: NiriCanvasMetrics
    ) -> some View {
        NiriCanvasPanCaptureView(
            onOneFingerDragBegan: {
                niriBeginGesture(sessionID: sessionID, inputKind: .oneFingerDrag)
            },
            onOneFingerDragChanged: { translation in
                niriHandleOneFingerDragChanged(
                    sessionID: sessionID,
                    translation: translation
                )
            },
            onOneFingerDragEnded: {
                niriEndGesture(
                    sessionID: sessionID,
                    layout: layout,
                    metrics: metrics
                )
            },
            onTwoFingerScrollBegan: {
                niriBeginGesture(sessionID: sessionID, inputKind: .twoFingerScroll)
            },
            onTwoFingerScroll: { delta in
                niriHandleTwoFingerScrollChanged(
                    sessionID: sessionID,
                    delta: delta
                )
            },
            onTwoFingerScrollEnded: {
                niriEndGesture(
                    sessionID: sessionID,
                    layout: layout,
                    metrics: metrics
                )
            },
            onPointerMoved: { location, size in
                niriHandlePointerMoved(
                    sessionID: sessionID,
                    location: location,
                    containerSize: size
                )
            }
        )
    }

    func niriCanvasKeyHandling<Content: View>(
        _ content: Content,
        sessionID: UUID,
        isOverviewOpen: Bool,
        isFocusedTileZoomed: Bool
    ) -> some View {
        content
            .onKeyPress(.upArrow) {
                guard isOverviewOpen else { return .ignored }
                sessionService.niriFocusNeighbor(sessionID: sessionID, vertical: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard isOverviewOpen else { return .ignored }
                sessionService.niriFocusNeighbor(sessionID: sessionID, vertical: 1)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard isOverviewOpen else { return .ignored }
                sessionService.niriFocusNeighbor(sessionID: sessionID, horizontal: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard isOverviewOpen else { return .ignored }
                sessionService.niriFocusNeighbor(sessionID: sessionID, horizontal: 1)
                return .handled
            }
            .onKeyPress(.return) {
                guard isOverviewOpen else { return .ignored }
                sessionService.toggleNiriOverview(sessionID: sessionID)
                return .handled
            }
            .onKeyPress(.escape) {
                if isFocusedTileZoomed {
                    sessionService.clearNiriFocusedTileZoom(sessionID: sessionID)
                    return .handled
                }
                guard isOverviewOpen else { return .ignored }
                sessionService.toggleNiriOverview(sessionID: sessionID)
                return .handled
            }
    }

    /// Smoothly animates camera so the focused item is visible.
    /// Called when keyboard navigation changes the active column/workspace/item.
    func niriAnimateCameraToFocusedColumn(sessionID: UUID) {
        guard var runtime = niriRuntimeBySession[sessionID] else { return }
        // Only auto-center if no gesture is active (keyboard-driven focus change)
        guard !runtime.gesture.isActive else { return }

        // Just reset camera offset to zero — the vertical centering is now handled
        // by niriFocusedItemCenteringY() computed inline, so the implicit .animation()
        // modifiers animate it smoothly (same approach as niriLeadingOffset for horizontal).
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            runtime.transientOffset = .zero
            runtime.cameraOffset = .zero
            niriRuntimeBySession[sessionID] = runtime
        }
    }

    /// Pure computed vertical offset to center the focused item in the viewport.
    /// Mirrors the role of niriLeadingOffset for horizontal centering — because it's
    /// computed inline, the implicit .animation(value: focusedItemID) modifier
    /// animates it in the same render pass with no frame gap.
    func niriFocusedItemCenteringY(
        layout: NiriCanvasLayout,
        metrics: NiriCanvasMetrics,
        containerSize: CGSize
    ) -> CGFloat {
        guard containerSize != .zero,
              let focusedItemID = layout.camera.focusedItemID,
              let wsIdx = layout.workspaces.firstIndex(where: { $0.id == layout.camera.activeWorkspaceID }),
              let colIdx = layout.workspaces[wsIdx].columns.firstIndex(where: { $0.id == layout.camera.activeColumnID })
        else { return 0 }

        let column = layout.workspaces[wsIdx].columns[colIdx]
        guard let itemIdx = column.items.firstIndex(where: { $0.id == focusedItemID }) else { return 0 }

        if layout.isOverviewOpen {
            // In overview, center the focused item vertically within the viewport
            let itemHeight = niriOverviewItemHeight(column: column, item: column.items[itemIdx], metrics: metrics)
            var yOffset: CGFloat = 0
            for i in 0..<itemIdx {
                yOffset += niriOverviewItemHeight(column: column, item: column.items[i], metrics: metrics)
                yOffset += metrics.itemSpacing
            }
            let centeringAdjust = (containerSize.height - itemHeight) / 2 - metrics.originY - metrics.headerHeight - 8
            return -(yOffset - centeringAdjust)
        } else {
            // Sum heights of all items above the focused one
            var yOffset: CGFloat = 0
            for i in 0..<itemIdx {
                yOffset += niriItemHeight(item: column.items[i], metrics: metrics)
                yOffset += 5 // item spacing (non-overview)
            }
            // Center the focused item in the viewport
            let focusedHeight = niriItemHeight(item: column.items[itemIdx], metrics: metrics)
            // When zoomed, compensate for the workspace header + VStack spacing (28px)
            // so the tile fills edge-to-edge within the viewport.
            let headerCompensation: CGFloat = metrics.zoomedItemID != nil ? (metrics.headerHeight + 8) : 0
            let centeringAdjust = (containerSize.height - focusedHeight) / 2 - metrics.originY - headerCompensation
            return -(yOffset - centeringAdjust)
        }
    }

}
