import AppKit
import SwiftUI

extension Notification.Name {
    static let niriSpotlightDismissRequested = Notification.Name("niriSpotlightDismissRequested")
}

struct MainWindowView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var workflowService: WorkflowService

    static let minSidebarWidth: CGFloat = 140
    static let maxSidebarWidth: CGFloat = 360
    static let defaultSidebarWidth: CGFloat = 220

    static let minCheckpointsWidth: CGFloat = 240
    static let maxCheckpointsWidth: CGFloat = 420
    static let defaultCheckpointsWidth: CGFloat = 300

    @State private var sidebarWidth: CGFloat = MainWindowView.defaultSidebarWidth
    @State private var checkpointsWidth: CGFloat = MainWindowView.defaultCheckpointsWidth

    var body: some View {
        ZStack {
            if coordinator.showingSettings {
                InlineSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    if sessionService.settings.sidebarVisible && !workflowService.layoutState.focusModeEnabled {
                        SessionSidebarView()
                            .frame(width: sidebarWidth)
                            .transition(.move(edge: .leading))
                            .simultaneousGesture(TapGesture().onEnded { requestNiriSpotlightDismissal() })

                        SidebarResizeHandle(width: $sidebarWidth, min: Self.minSidebarWidth, max: Self.maxSidebarWidth)
                    }

                    ZStack(alignment: .top) {
                        SessionContainerView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transaction { t in t.animation = nil }

                        TabBarOverlay()
                            .simultaneousGesture(TapGesture().onEnded { requestNiriSpotlightDismissal() })
                    }

                    if coordinator.showingCheckpoints {
                        SidebarResizeHandle(width: $checkpointsWidth, min: Self.minCheckpointsWidth, max: Self.maxCheckpointsWidth)

                        CheckpointsSidebar()
                            .frame(width: checkpointsWidth)
                            .transition(.move(edge: .trailing))
                            .simultaneousGesture(TapGesture().onEnded { requestNiriSpotlightDismissal() })
                    }
                }
            }

            // Command palette overlay (#4)
            if coordinator.showingCommandPalette {
                CommandPaletteOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
            }

            // Quick switch overlay (#6)
            if coordinator.showingQuickSwitch {
                QuickSwitchOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
            }

            // Rename session overlay
            if coordinator.showingRenameSessionSheet {
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { coordinator.cancelRenameSession() }

                    RenameSessionSheet()
                        .environmentObject(coordinator)
                        .padding(.top, 60)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(100)
                .onKeyPress(.escape) { coordinator.cancelRenameSession(); return .handled }
            }

            // Niri onboarding coaching overlay
            if coordinator.showingNiriOnboarding {
                NiriOnboardingOverlay()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(99)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowConfigurator())
        .animation(.easeOut(duration: 0.12), value: sessionService.settings.sidebarVisible)
        .animation(.spring(duration: 0.28, bounce: 0.12), value: coordinator.showingCommandPalette)
        .animation(.spring(duration: 0.28, bounce: 0.12), value: coordinator.showingQuickSwitch)
        .animation(.spring(duration: 0.25, bounce: 0.1), value: coordinator.showingRenameSessionSheet)
        .animation(.easeOut(duration: 0.12), value: coordinator.showingCheckpoints)
        .animation(.easeOut(duration: 0.15), value: coordinator.showingDiffOverlay)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: coordinator.showingNiriOnboarding)
        .onAppear {
            workflowService.setFocusedSession(sessionService.selectedSessionID)
            maybePresentNiriOnboardingIfNeeded()
        }
        .onChange(of: sessionService.selectedSessionID) { _, newValue in
            workflowService.setFocusedSession(newValue)
            maybePresentNiriOnboardingIfNeeded()
        }
        .onChange(of: sessionService.settings.niriCanvasEnabled) { _, _ in
            maybePresentNiriOnboardingIfNeeded()
        }
        .onChange(of: sessionService.settings.hasSeenFirstRun) { _, _ in
            maybePresentNiriOnboardingIfNeeded()
        }
        // Note: hasSeenNiriOnboarding changes are NOT observed here so that
        // resetting the walkthrough from settings requires an app restart,
        // matching the fresh-user experience.
        .modifier(MainWindowSheets())
        .modifier(MainWindowAlerts())
    }

    private func maybePresentNiriOnboardingIfNeeded() {
        let shouldShow = NiriOnboardingGate.shouldAutoShow(
            settings: sessionService.settings,
            hasActiveSession: sessionService.selectedSessionID != nil,
            isAlreadyPresented: coordinator.showingNiriOnboarding
        )
        if shouldShow {
            coordinator.showingNiriOnboarding = true
        }
    }

    private func requestNiriSpotlightDismissal() {
        NotificationCenter.default.post(name: .niriSpotlightDismissRequested, object: nil)
    }
}
