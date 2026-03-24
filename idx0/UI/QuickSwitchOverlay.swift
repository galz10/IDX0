import SwiftUI

struct QuickSwitchOverlay: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var workflowService: WorkflowService
    @Environment(\.themeColors) private var tc

    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hoverReady = false

    var body: some View {
        ZStack {
            // Invisible dismiss layer (no dimming)
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tc.accent)

                    TextField("Switch to session...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($queryFocused)
                        .onSubmit { switchToSelected() }
                        .onChange(of: query) { _, _ in selectedIndex = 0 }

                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(tc.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }

                    keyBadge("esc")
                        .onTapGesture { dismiss() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                Rectangle()
                    .fill(tc.divider)
                    .frame(height: 1)

                if !filteredSessions.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredSessions.prefix(10).enumerated()), id: \.element.id) { index, session in
                                    sessionRow(session, isSelected: index == selectedIndex)
                                        .id(session.id)
                                        .onTapGesture {
                                            selectedIndex = index
                                            switchToSelected()
                                        }
                                        .onHover { hovering in
                                            guard hoverReady, hovering else { return }
                                            selectedIndex = index
                                        }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .scrollIndicators(.hidden)
                        .onChange(of: selectedIndex) { _, newValue in
                            if let session = filteredSessions.prefix(10).dropFirst(newValue).first {
                                withAnimation(.easeOut(duration: 0.08)) {
                                    proxy.scrollTo(session.id, anchor: .center)
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundStyle(tc.tertiaryText)
                        Text("No matching sessions")
                            .font(.system(size: 11))
                            .foregroundStyle(tc.tertiaryText)
                    }
                    .padding(12)
                }
            }
            .frame(width: 420)
            .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(tc.surface2.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
            .padding(.top, 60)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            hoverReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                queryFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hoverReady = true
            }
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor(for: session))
                .frame(width: 6, height: 6)

            Image(systemName: session.isWorktreeBacked ? "arrow.triangle.branch" : "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? tc.accent : tc.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    isSelected ? tc.accent.opacity(0.1) : tc.surface1,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(FuzzyMatch.highlight(query: query, in: session.title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(session.id == sessionService.selectedSessionID ? tc.secondaryText : tc.primaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let branch = session.branchName, !branch.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 7))
                            Text(branch)
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundStyle(tc.tertiaryText)
                    }

                    Text(session.subtitle)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(tc.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Text(relativeTime(session.lastActiveAt))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(tc.mutedText)

            if session.id == sessionService.selectedSessionID {
                Text("current")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(tc.tertiaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tc.surface1, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? tc.surface0 : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tc.surface1, in: RoundedRectangle(cornerRadius: 3))
    }

    private func statusColor(for session: Session) -> Color {
        if let reason = session.latestAttentionReason {
            switch reason {
            case .error: return .red
            case .needsInput: return .orange
            case .completed: return .green
            case .notification: return .yellow
            }
        }
        if session.agentActivity?.isActive == true { return .green }
        if session.agentActivity?.isWaiting == true { return .orange }
        return tc.mutedText
    }

    private var filteredSessions: [Session] {
        let sorted = sessionService.sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return sorted }
        return sorted
            .filter { session in
                let searchText = "\(session.title) \(session.branchName ?? "") \(session.subtitle)".lowercased()
                return FuzzyMatch.matches(query: normalized, text: searchText)
            }
            .sorted { lhs, rhs in
                let lhsText = "\(lhs.title) \(lhs.branchName ?? "") \(lhs.subtitle)".lowercased()
                let rhsText = "\(rhs.title) \(rhs.branchName ?? "") \(rhs.subtitle)".lowercased()
                return FuzzyMatch.score(query: normalized, text: lhsText) > FuzzyMatch.score(query: normalized, text: rhsText)
            }
    }

    private func moveSelection(_ delta: Int) {
        let max = min(filteredSessions.count, 10) - 1
        guard max >= 0 else { return }
        selectedIndex = min(max, Swift.max(0, selectedIndex + delta))
    }

    private func switchToSelected() {
        let sessions = Array(filteredSessions.prefix(10))
        guard selectedIndex < sessions.count else { return }
        let session = sessions[selectedIndex]
        dismiss()
        sessionService.focusSession(session.id)
    }

    private func dismiss() {
        coordinator.showingQuickSwitch = false
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
