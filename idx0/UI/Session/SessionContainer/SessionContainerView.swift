import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SessionContainerView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @EnvironmentObject var sessionService: SessionService
    @EnvironmentObject var workflowService: WorkflowService
    @Environment(\.themeColors) var tc

    @State var errorMessage: String?
    @State var niriRuntimeBySession: [UUID: NiriCanvasRuntimeState] = [:]
    @State var niriDraggedItemBySession: [UUID: UUID] = [:]
    @State var niriEdgeAutoScrollBySession: [UUID: NiriEdgeAutoScrollRuntime] = [:]
    @State var niriHoverActivateTaskBySession: [UUID: Task<Void, Never>] = [:]
    @State var niriHoverActivateTargetBySession: [UUID: UUID] = [:]
    @State var niriColumnResizeTranslation: [NiriColumnResizeKey: CGFloat] = [:]
    @State var niriItemResizeTranslation: [NiriItemResizeKey: CGFloat] = [:]
    @State var niriResizeVisualizerBySession: [UUID: NiriResizeVisualizerState] = [:]
    @State var niriQuickAddMenuPresented = false
    @State var niriWorkspaceSwitchOSD: String?
    @State var niriWorkspaceSwitchOSDTask: Task<Void, Never>?
    @State var niriDropInsertionTarget: NiriDropInsertionTarget?
    @State var niriTileDrag: NiriTileDragState?

    var body: some View {
        ZStack {
            if let session = sessionService.selectedSession {
                if sessionService.settings.niriCanvasEnabled {
                    niriCanvasSurface(session: session)
                        .id(session.id)
                        .transition(.opacity)
                } else {
                    if let controller = sessionService.controller(for: session.id) {
                        if let browserState = session.browserState,
                           browserState.isVisible,
                           let browserController = sessionService.browserController(for: session.id) {
                            splitView(
                                session: session,
                                terminalController: controller,
                                browserController: browserController,
                                browserState: browserState
                            )
                        } else {
                            terminalSurface(session: session, controller: controller)
                        }
                    } else {
                        emptyState
                    }
                }
            } else {
                emptyState
            }

            // Diff overlay (Cmd+D)
            if coordinator.showingDiffOverlay, let sessionID = sessionService.selectedSessionID {
                DiffOverlayView(sessionID: sessionID)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .animation(.easeOut(duration: 0.12), value: sessionService.selectedSessionID)
        .onChange(of: sessionService.selectedSessionID) { _, _ in
            niriQuickAddMenuPresented = false
        }
        .onChange(of: sessionService.settings.niriCanvasEnabled) { _, enabled in
            if !enabled {
                niriQuickAddMenuPresented = false
            }
        }
        .onChange(of: coordinator.showingSettings) { _, showing in
            if showing {
                niriQuickAddMenuPresented = false
            }
        }
        .onChange(of: coordinator.showingCommandPalette) { _, showing in
            if showing {
                niriQuickAddMenuPresented = false
            }
        }
        .onChange(of: coordinator.showingQuickSwitch) { _, showing in
            if showing {
                niriQuickAddMenuPresented = false
            }
        }
        .onChange(of: coordinator.showingRenameSessionSheet) { _, showing in
            if showing {
                niriQuickAddMenuPresented = false
            }
        }
    }

}
