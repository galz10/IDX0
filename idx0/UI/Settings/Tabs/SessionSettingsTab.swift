import SwiftUI

// MARK: - Sessions Tab

struct SessionSettingsTab: View {
    @ObservedObject var sessionService: SessionService
    @ObservedObject var workflowService: WorkflowService

    var body: some View {
        Form {
            Section("Behavior") {
                Picker("New Session Behavior", selection: enumBinding(\.newSessionBehavior)) {
                    ForEach(NewSessionBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayLabel).tag(behavior)
                    }
                }
                Text("What happens when you press \u{2318}T")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Create Worktree By Default For Repo Sessions",
                        isOn: binding(\.defaultCreateWorktreeForRepoSessions)
                    )
                    Text("When enabled, repo-backed sessions always create a worktree")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Picker("Restore Behavior", selection: enumBinding(\.restoreBehavior)) {
                    ForEach(RestoreBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayLabel).tag(behavior)
                    }
                }
                Text("What to restore when IDX0 relaunches")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Cleanup On Close",
                        isOn: binding(\.cleanupOnClose)
                    )
                    Text("When off, open tiles are restored next launch. When on, tile layouts are cleared on app close.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if sessionService.settings.appMode.showsVibeFeatures {
                Section("Vibe Tools") {
                    Picker(
                        "Default Vibe Tool",
                        selection: Binding(
                            get: { sessionService.settings.defaultVibeToolID ?? "none" },
                            set: { value in sessionService.saveSettings { $0.defaultVibeToolID = value == "none" ? nil : value } }
                        )
                    ) {
                        Text("None").tag("none")
                        ForEach(workflowService.vibeTools, id: \.id) { tool in
                            Text(tool.isInstalled ? tool.displayName : "\(tool.displayName) (Not Installed)")
                                .tag(tool.id)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Cmd+N Auto-Launch Default Vibe Tool",
                            isOn: binding(\.autoLaunchDefaultVibeToolOnCmdN)
                        )
                        Text("Automatically start the default vibe tool when creating a session with \u{2318}N")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
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
