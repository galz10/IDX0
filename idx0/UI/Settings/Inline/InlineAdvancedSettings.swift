import SwiftUI

// MARK: - Advanced

struct InlineAdvancedSettings: View {
  @ObservedObject var sessionService: SessionService
  @EnvironmentObject private var appUpdateService: AppUpdateService
  @Environment(\.themeColors) private var tc

  @State private var onboardingResetPending = false
  @State private var fullOnboardingResetPending = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingSectionHeader(title: "Shell")

      SettingRowView(label: "Preferred Shell Path", caption: "Leave empty to use the system default shell. Changes apply to new sessions.") {
        TextField(
          "/bin/zsh",
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
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
        )
        .frame(maxWidth: 280)
      }

      SettingRowView(
        label: "Terminal Startup Command Template",
        caption: "Optional command sent when a new terminal controller starts. Use ${WORKDIR} and ${SESSION_ID}. Leave empty to disable."
      ) {
        TextField(
          "cd ${WORKDIR}",
          text: Binding(
            get: { sessionService.settings.terminalStartupCommandTemplate ?? "" },
            set: { newValue in
              sessionService.saveSettings { settings in
                let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.terminalStartupCommandTemplate = cleaned.isEmpty ? nil : cleaned
              }
            }
          )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
        .overlay(
          RoundedRectangle(cornerRadius: 4)
            .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
        )
        .frame(maxWidth: 420)
      }

      SettingDivider()
      SettingSectionHeader(title: "Updates")

      SettingToggleRow(
        label: "Auto-check for updates",
        caption: "Check in the background after startup and every few hours.",
        isOn: Binding(
          get: { sessionService.settings.autoCheckForUpdates },
          set: { newValue in
            withAnimation(.easeOut(duration: 0.15)) {
              sessionService.saveSettings { settings in
                settings.autoCheckForUpdates = newValue
              }
              appUpdateService.refreshPolicy()
            }
          }
        )
      )

      SettingRowView(label: "Status", caption: appUpdateService.statusDescription) {
        HStack(spacing: 8) {
          if let actionTitle = appUpdateService.primaryActionTitle {
            Button {
              appUpdateService.performPrimaryAction()
            } label: {
              Text(actionTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tc.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                  RoundedRectangle(cornerRadius: 4)
                    .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(!appUpdateService.canPerformPrimaryAction)
          }

          if let lastChecked = appUpdateService.state.lastCheckedAt {
            Text(lastChecked.formatted(date: .abbreviated, time: .shortened))
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(tc.tertiaryText)
          }
        }
      }

      SettingDivider()
      SettingSectionHeader(title: "Reset")

      VStack(alignment: .leading, spacing: 10) {
        if fullOnboardingResetPending {
          resetConfirmation("All onboarding will show on next launch. Restart IDX0 to see it.")
        } else if onboardingResetPending {
          resetConfirmation("Niri walkthrough will show on next launch. Restart IDX0 to see it.")
        } else {
          Button {
            sessionService.saveSettings { settings in
              settings.hasSeenNiriOnboarding = false
            }
            onboardingResetPending = true
          } label: {
            Text("Reset Niri Walkthrough")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(tc.secondaryText)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
              .overlay(
                RoundedRectangle(cornerRadius: 4)
                  .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
              )
          }
          .buttonStyle(.plain)

          Button {
            sessionService.saveSettings { settings in
              settings.hasSeenFirstRun = false
              settings.hasSeenNiriOnboarding = false
            }
            fullOnboardingResetPending = true
          } label: {
            Text("Reset All Onboarding")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(tc.secondaryText)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
              .overlay(
                RoundedRectangle(cornerRadius: 4)
                  .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
              )
          }
          .buttonStyle(.plain)
        }

        Button {
          sessionService.saveSettings { settings in
            let preserveFirstRun = settings.hasSeenFirstRun
            let preserveNiriOnboarding = settings.hasSeenNiriOnboarding
            settings = AppSettings()
            settings.hasSeenFirstRun = preserveFirstRun
            settings.hasSeenNiriOnboarding = preserveNiriOnboarding
          }
        } label: {
          Text("Reset All Settings")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.red.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 4)
                .stroke(.red.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)

        Text("This will reset all settings to their defaults. This cannot be undone.")
          .font(.system(size: 11))
          .foregroundStyle(tc.tertiaryText)
      }
      .padding(.vertical, 4)
    }
  }

  private func resetConfirmation(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 12))
        .foregroundStyle(.green)
      Text(message)
        .font(.system(size: 11))
        .foregroundStyle(tc.secondaryText)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
  }
}
