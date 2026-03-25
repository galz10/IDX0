import SwiftUI

// MARK: - Tab Bar Overlay

struct TabBarOverlay: View {
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var appUpdateService: AppUpdateService
    @Environment(\.themeColors) private var tc

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Reserve space for traffic lights only when sidebar is hidden
            // (when sidebar is visible, traffic lights sit over the sidebar)
            if !sessionService.settings.sidebarVisible {
                Color.clear
                    .frame(width: 78, height: 28)
            } else {
                Color.clear
                    .frame(width: 8, height: 28)
            }

            Button {
                appUpdateService.performPrimaryAction()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(updateIndicatorColor)
                        .frame(width: 7, height: 7)

                    if appUpdateService.state.status == .checking || appUpdateService.state.status == .downloading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.55)
                            .frame(width: 8, height: 8)
                    } else {
                        Image(systemName: updateIconName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(isHovering ? tc.secondaryText : tc.mutedText)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tc.surface0.opacity(0.8), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!appUpdateService.canPerformPrimaryAction)
            .help(updateButtonHelp)
            .padding(.trailing, 6)

            // Session info
            if let session = sessionService.selectedSession {
                Text(Self.displayTitle(for: session))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tc.primaryText)
                    .lineLimit(1)
                    .help(session.title)

                // Branch pill (Ghostty-style)
                if let branch = session.branchName, !branch.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .medium))
                        Text(branch)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(tc.secondaryText)
                    .background(Capsule().fill(tc.surface1))
                    .contentShape(Capsule())
                    .padding(.leading, 6)
                }

                // Agent activity indicator
                if let activity = session.agentActivity, activity.isActive {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                        Text(String(activity.description.prefix(30)))
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.leading, 6)
                }
            }

            Spacer(minLength: 0)

            // Attention indicator for background sessions
            let needsAttention = coordinator.terminalMonitor.sessionsNeedingAttention()
            if needsAttention > 0 {
                Button {
                    focusNextAttentionSession()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                        Text("\(needsAttention) waiting")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }

            if !sessionService.settings.niriCanvasEnabled {
                Button {
                    if let selected = sessionService.selectedSessionID {
                        sessionService.toggleBrowserSplit(for: selected)
                    }
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isHovering ? tc.secondaryText : tc.mutedText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Toggle Browser Split (\u{2318}\u{21e7}B)")
            }

            // Sidebar toggle
            Button {
                sessionService.saveSettings { $0.sidebarVisible.toggle() }
            } label: {
                Image(systemName: sessionService.settings.sidebarVisible ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHovering ? tc.secondaryText : tc.mutedText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (\u{2318}B)")
            .padding(.leading, 4)
            .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(tc.windowBackground)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    /// Strip `user@host:` prefix from terminal titles to show just the path.
    static func displayTitle(for session: Session) -> String {
        let title = session.title
        if session.hasCustomTitle { return title }
        if let colonIndex = title.firstIndex(of: ":") {
            let beforeColon = title[title.startIndex..<colonIndex]
            if beforeColon.contains("@") {
                return String(title[title.index(after: colonIndex)...])
            }
        }
        return title
    }

    private func focusNextAttentionSession() {
        for (sessionID, result) in coordinator.terminalMonitor.agentStates {
            if result.hasDetectedAgent
                && (result.state == .waitingForInput || result.state == .error)
                && sessionID != sessionService.selectedSessionID {
                sessionService.focusSession(sessionID)
                return
            }
        }
    }

    private var updateIndicatorColor: Color {
        switch appUpdateService.state.status {
        case .disabled:
            return .gray.opacity(0.55)
        case .idle, .upToDate:
            return .mint.opacity(0.8)
        case .checking:
            return .blue.opacity(0.85)
        case .available:
            return .orange
        case .downloading:
            return .blue
        case .downloaded:
            return .green
        case .error:
            return .red
        }
    }

    private var updateIconName: String {
        switch appUpdateService.state.status {
        case .downloaded:
            return "arrow.down.app.fill"
        case .error:
            return "exclamationmark.triangle"
        default:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var updateButtonHelp: String {
        guard let actionTitle = appUpdateService.primaryActionTitle else {
            return appUpdateService.statusDescription
        }
        return "\(actionTitle) • \(appUpdateService.statusDescription)"
    }
}
