import SwiftUI

struct InlineSettingsView: View {
    @EnvironmentObject private var sessionService: SessionService
    @EnvironmentObject private var workflowService: WorkflowService
    @EnvironmentObject private var coordinator: AppCoordinator
    @Environment(\.themeColors) private var tc

    @State private var selectedTab: SettingsTab = .general
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case appearance = "Appearance"
        case sessions = "Sessions"
        case keyboard = "Keyboard"
        case safety = "Safety"
        case advanced = "Advanced"

        var icon: String {
            switch self {
            case .general: return "gear"
            case .appearance: return "paintbrush"
            case .sessions: return "terminal"
            case .keyboard: return "keyboard"
            case .safety: return "shield"
            case .advanced: return "gearshape.2"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar nav
            VStack(alignment: .leading, spacing: 0) {
                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tc.tertiaryText)

                    TextField("Search settings", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tc.surface0, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 10)
                .padding(.top, 36)
                .padding(.bottom, 14)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    settingsNavItem(tab)
                }

                Spacer()

                Button {
                    coordinator.showingSettings = false
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8, weight: .bold))
                        Text("Back")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tc.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .idxHitTarget(size: HitTargetSize.dense, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
            .frame(width: 160)
            .background(tc.sidebarBackground)

            Rectangle()
                .fill(tc.divider)
                .frame(width: 1)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Page title
                    Text(selectedTab.rawValue)
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(tc.primaryText)
                        .padding(.bottom, 16)

                    switch selectedTab {
                    case .general:
                        InlineGeneralSettings(sessionService: sessionService)
                    case .appearance:
                        InlineAppearanceSettings(sessionService: sessionService)
                    case .sessions:
                        InlineSessionSettings(sessionService: sessionService, workflowService: workflowService)
                    case .keyboard:
                        InlineKeyboardSettings(sessionService: sessionService)
                    case .safety:
                        InlineSafetySettings(sessionService: sessionService)
                    case .advanced:
                        InlineAdvancedSettings(sessionService: sessionService)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 24)
                .frame(maxWidth: 600, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tc.windowBackground)
        }
        .onAppear {
            workflowService.refreshVibeTools()
        }
        .onKeyPress(.escape) {
            coordinator.showingSettings = false
            return .handled
        }
    }

    @ViewBuilder
    private func settingsNavItem(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab

        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? tc.accent : tc.tertiaryText)
                    .frame(width: 14)
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? tc.primaryText : tc.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isSelected {
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(tc.accent)
                                .frame(width: 2)
                            Color.clear
                        }
                    }
                }
            )
            .idxFullWidthHitRow()
        }
        .buttonStyle(.plain)
    }
}
