import SwiftUI

struct SessionSidebarRowView: View {
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.themeColors) private var tc

    let session: Session
    let isLast: Bool
    /// Non-nil when multiple siblings share the same display title.
    let disambiguationIndex: Int?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            // Tree guide
            treeGuide
                .frame(width: 16)

            // Terminal icon with status color
            statusIcon
                .frame(width: 16)

            // Title + branch info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(tc.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let idx = disambiguationIndex {
                        Text("#\(idx)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(tc.tertiaryText)
                    }
                }

                // Branch + diff stats (plain text)
                if let branch = session.branchName, !branch.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7, weight: .medium))
                        Text(branch)
                            .font(.system(size: 9, weight: .regular, design: .monospaced))

                        if let stat = session.lastDiffStat, (stat.additions > 0 || stat.deletions > 0) {
                            HStack(spacing: 2) {
                                if stat.additions > 0 {
                                    Text("+\(stat.additions)")
                                        .foregroundStyle(.green.opacity(0.65))
                                }
                                if stat.deletions > 0 {
                                    Text("-\(stat.deletions)")
                                        .foregroundStyle(.red.opacity(0.65))
                                }
                            }
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(1)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 4)

            // Close button (visible on hover)
            if isHovering {
                Button {
                    sessionService.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tc.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(tc.surface2.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .idxHitTarget()
                }
                .buttonStyle(.plain)
                .help("Close Session")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .help(session.title)
    }

    // MARK: - Display Title

    /// Strip `user@host:` prefix to show just the path.
    private var displayTitle: String {
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

    // MARK: - Tree Guide

    @ViewBuilder
    private var treeGuide: some View {
        Canvas { context, size in
            let midX = size.width / 2
            let midY = size.height / 2
            let color = tc.surface2

            var vPath = Path()
            vPath.move(to: CGPoint(x: midX, y: 0))
            vPath.addLine(to: CGPoint(x: midX, y: isLast ? midY : size.height))
            context.stroke(vPath, with: .color(color), lineWidth: 1)

            var hPath = Path()
            hPath.move(to: CGPoint(x: midX, y: midY))
            hPath.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(hPath, with: .color(color), lineWidth: 1)
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        let scanResult = coordinator.terminalMonitor.agentStates[session.id]
        let scanState: AgentState? = (scanResult?.hasDetectedAgent == true) ? scanResult?.state : nil
        let state = scanState ?? agentActivityState

        ZStack(alignment: .topTrailing) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle({
                    switch state {
                    case .thinking, .working, .completed: return Color.green
                    case .waitingForInput: return Color.orange
                    case .error: return Color.red
                    case .idle: return tc.tertiaryText
                    }
                }())

            if state == .thinking || state == .working || state == .waitingForInput {
                ActivityDot(color: state == .waitingForInput ? .orange : .green)
                    .offset(x: 3, y: -2)
            }
        }
    }

    private var agentActivityState: AgentState {
        guard let activity = session.agentActivity else { return .idle }
        switch activity {
        case .active: return .working
        case .waiting: return .waitingForInput
        case .completed: return .completed
        case .error: return .error
        }
    }
}

// MARK: - Activity Dot

private struct ActivityDot: View {
    let color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
