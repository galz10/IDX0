import SwiftUI

struct BrowserControlConsentSheet: View {
    @EnvironmentObject private var sessionService: SessionService

    let prompt: BrowserControlConsentPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.title3.weight(.semibold))

            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText = prompt.setupErrorMessage, !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if prompt.isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Configuring browser control...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(secondaryActionTitle) {
                    sessionService.performBrowserControlConsentSecondaryAction()
                }
                .disabled(prompt.isInstalling)

                Button(primaryActionTitle) {
                    sessionService.performBrowserControlConsentPrimaryAction()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.isInstalling)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var titleText: String {
        switch prompt.mode {
        case .firstUse, .settingsEnable:
            return "Enable Browser Control?"
        case .settingsRerun:
            return "Re-run Browser Control Setup?"
        }
    }

    private var bodyText: String {
        switch prompt.mode {
        case .firstUse, .settingsEnable:
            return "This enables agent tools to drive browser automation from IDX0 by installing and configuring the local MCP browser-control server."
        case .settingsRerun:
            return "This will reinstall and reconfigure browser control for supported installed CLIs."
        }
    }

    private var primaryActionTitle: String {
        switch prompt.mode {
        case .firstUse, .settingsEnable:
            return "Enable Browser Control"
        case .settingsRerun:
            return "Re-run Browser Control Setup"
        }
    }

    private var secondaryActionTitle: String {
        switch prompt.mode {
        case .firstUse, .settingsEnable:
            return "Not now"
        case .settingsRerun:
            return "Close"
        }
    }
}
