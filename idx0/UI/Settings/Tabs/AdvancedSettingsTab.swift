import SwiftUI

// MARK: - Advanced Tab

struct AdvancedSettingsTab: View {
  @ObservedObject var sessionService: SessionService
  @EnvironmentObject private var appUpdateService: AppUpdateService

  var body: some View {
    Form {
      Section("Shell") {
        TextField(
          "Preferred Shell Path",
          text: Binding(
            get: { sessionService.settings.preferredShellPath ?? "" },
            set: { newValue in
              sessionService.saveSettings { settings in
                let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.preferredShellPath = cleaned.isEmpty ? nil : cleaned
              }
            }
          )
        )
        Text("Leave empty to use the system default shell")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      Section("Updates") {
        Toggle(
          "Auto-check for updates",
          isOn: Binding(
            get: { sessionService.settings.autoCheckForUpdates },
            set: { newValue in
              sessionService.saveSettings { settings in
                settings.autoCheckForUpdates = newValue
              }
              appUpdateService.refreshPolicy()
            }
          )
        )

        Text(appUpdateService.statusDescription)
          .font(.caption)
          .foregroundStyle(.tertiary)

        if let lastChecked = appUpdateService.state.lastCheckedAt {
          Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }

        if let actionTitle = appUpdateService.primaryActionTitle {
          Button(actionTitle) {
            appUpdateService.performPrimaryAction()
          }
          .disabled(!appUpdateService.canPerformPrimaryAction)
        }
      }

      Section("Reset") {
        Button("Reset Niri Walkthrough (requires restart)") {
          sessionService.saveSettings { settings in
            settings.hasSeenNiriOnboarding = false
          }
        }

        Button("Reset All Onboarding (requires restart)") {
          sessionService.saveSettings { settings in
            settings.hasSeenFirstRun = false
            settings.hasSeenNiriOnboarding = false
          }
        }

        Button("Reset All Settings to Defaults") {
          sessionService.saveSettings { settings in
            let preserveFirstRun = settings.hasSeenFirstRun
            let preserveNiriOnboarding = settings.hasSeenNiriOnboarding
            settings = AppSettings()
            settings.hasSeenFirstRun = preserveFirstRun
            settings.hasSeenNiriOnboarding = preserveNiriOnboarding
          }
        }
        .foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .padding(10)
  }
}
