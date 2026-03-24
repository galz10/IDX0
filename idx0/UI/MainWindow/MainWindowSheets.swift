import SwiftUI

// MARK: - Sheets Modifier

struct MainWindowSheets: ViewModifier {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var workflowService: WorkflowService

    /// Captured once on appear so that resetting hasSeenFirstRun mid-session
    /// does NOT immediately re-show the first-run sheet (requires restart).
    @State private var shouldShowFirstRun: Bool?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if shouldShowFirstRun == nil {
                    shouldShowFirstRun = !sessionService.settings.hasSeenFirstRun
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { shouldShowFirstRun == true },
                    set: { showing in
                        if !showing {
                            shouldShowFirstRun = false
                            sessionService.saveSettings { $0.hasSeenFirstRun = true }
                        }
                    }
                )
            ) {
                FirstRunSheet()
                    .environmentObject(coordinator)
                    .environmentObject(sessionService)
                    .environmentObject(workflowService)
            }
            .sheet(isPresented: $coordinator.showingNewSessionSheet) {
                NewSessionSheet(preset: coordinator.newSessionPreset)
                    .environmentObject(coordinator)
                    .environmentObject(sessionService)
                    .environmentObject(workflowService)
                    .frame(width: 480)
            }
            // Rename session is now an overlay in MainWindowView.
            .sheet(isPresented: $coordinator.showingKeyboardShortcuts) {
                KeyboardShortcutsSheet()
                    .environmentObject(sessionService)
            }
            // Niri onboarding is now an overlay in MainWindowView, not a sheet.
            .sheet(item: $workflowService.activeHandoffComposer) { draft in
                HandoffComposerSheet(initialDraft: draft)
                    .environmentObject(sessionService)
                    .environmentObject(workflowService)
                    .frame(width: 560)
            }
            .sheet(item: $sessionService.pendingWorktreeInspector) { request in
                WorktreeInspectorSheet(repoPath: request.repoPath)
                    .environmentObject(sessionService)
                    .frame(width: 680, height: 460)
            }
    }
}

