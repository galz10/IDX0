import SwiftUI

// MARK: - Sessions

struct InlineSessionSettings: View {
    @ObservedObject var sessionService: SessionService
    @ObservedObject var workflowService: WorkflowService
    @Environment(\.themeColors) private var tc

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingSectionHeader(title: "Behavior")

            SettingRowView(label: "New Session", caption: "Controls what happens when you press \u{2318}T. Quick creates an instant terminal, Structured opens the full setup dialog.") {
                ThemedPicker(
                    options: NewSessionBehavior.allCases.map { ($0.displayLabel, $0) },
                    selection: enumBinding(\.newSessionBehavior)
                )
            }

            SettingToggleRow(
                label: "Create Worktree By Default",
                caption: "When enabled, repo-backed sessions always create a worktree.",
                isOn: binding(\.defaultCreateWorktreeForRepoSessions)
            )

            SettingRowView(label: "Restore on Relaunch", caption: "What to bring back when IDX0 restarts.") {
                ThemedPicker(
                    options: RestoreBehavior.allCases.map { ($0.displayLabel, $0) },
                    selection: enumBinding(\.restoreBehavior)
                )
            }

            SettingToggleRow(
                label: "Cleanup On Close",
                caption: "When enabled, tile layouts are cleared when a session is closed. When disabled, open tiles are restored on next launch.",
                isOn: binding(\.cleanupOnClose)
            )

            if sessionService.settings.appMode.showsVibeFeatures {
                SettingDivider()
                SettingSectionHeader(title: "Vibe Tools")

                SettingRowView(label: "Default Tool", caption: "The agentic CLI to auto-launch in new sessions.") {
                    ThemedPicker(
                        options: [("None", "none")] + workflowService.vibeTools.map {
                            ($0.isInstalled ? $0.displayName : "\($0.displayName) (N/A)", $0.id)
                        },
                        selection: Binding(
                            get: { sessionService.settings.defaultVibeToolID ?? "none" },
                            set: { value in sessionService.saveSettings { $0.defaultVibeToolID = value == "none" ? nil : value } }
                        )
                    )
                }

                SettingToggleRow(
                    label: "Auto-Launch on \u{2318}N",
                    caption: nil,
                    isOn: binding(\.autoLaunchDefaultVibeToolOnCmdN)
                )
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { sessionService.settings[keyPath: keyPath] },
            set: { value in sessionService.saveSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func enumBinding<Value: Hashable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { sessionService.settings[keyPath: keyPath] },
            set: { value in sessionService.saveSettings { $0[keyPath: keyPath] = value } }
        )
    }
}
