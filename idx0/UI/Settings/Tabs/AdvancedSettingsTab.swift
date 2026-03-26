import SwiftUI

// MARK: - Advanced Tab

struct AdvancedSettingsTab: View {
    @ObservedObject var sessionService: SessionService

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

            Section("Browser Control") {
                if sessionService.settings.browserControlConsent == .enabled {
                    Button("Re-run Browser Control Setup") {
                        sessionService.presentBrowserControlConsentPromptFromSettings()
                    }
                } else {
                    Button("Enable Browser Control") {
                        sessionService.presentBrowserControlConsentPromptFromSettings()
                    }
                }

                Button("Reset Browser Control Consent (for testing)") {
                    sessionService.resetBrowserControlConsentForTesting()
                }

                Text(browserControlStatusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    private var browserControlStatusText: String {
        switch sessionService.settings.browserControlConsent {
        case .undecided:
            return "Browser control has not been configured yet."
        case .enabled:
            return "Browser control is enabled."
        case .declined:
            return "Browser control prompt was declined. You can enable it any time."
        }
    }
}
