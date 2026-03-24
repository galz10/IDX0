import SwiftUI

// MARK: - Spotlight Item

struct TileSpotlightItem: Identifiable {
    let id: String
    let icon: String
    var iconImageName: String? = nil
    let title: String
    let subtitle: String
    let searchText: String
    var shortcut: String? = nil
    var section: SpotlightSection = .apps
    let run: () -> Void

    enum SpotlightSection: Int, Comparable {
        case apps = 0
        case tools = 1
        case commands = 2

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var header: String {
            switch self {
            case .apps: return "ADD TILE"
            case .tools: return "AGENTIC CLIS"
            case .commands: return "COMMANDS"
            }
        }
    }
}

// MARK: - Expanding Spotlight

struct NiriTileSpotlight: View {
    @Environment(\.themeColors) private var tc
    @Binding var isPresented: Bool

    let items: [TileSpotlightItem]

    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    /// Blocks mouse interaction briefly after appearing so the scroll view
    /// doesn't steal events when the cursor happens to sit over it.
    @State private var interactionReady = false
    @State private var lastSelectionSource: SelectionSource = .keyboard
    private enum SelectionSource { case keyboard, hover }

    private var filtered: [TileSpotlightItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return items }
        return items.filter { item in
            FuzzyMatch.matches(query: normalized, text: item.searchText)
        }.sorted { lhs, rhs in
            let scoreDiff = FuzzyMatch.score(query: normalized, text: lhs.searchText) - FuzzyMatch.score(query: normalized, text: rhs.searchText)
            if scoreDiff != 0 { return scoreDiff > 0 }
            return lhs.section < rhs.section
        }
    }

    /// Group filtered items by section, preserving order.
    private var groupedSections: [(section: TileSpotlightItem.SpotlightSection, items: [TileSpotlightItem])] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // When searching, don't group — show flat ranked results
        guard normalized.isEmpty else {
            return [(.apps, filtered)]
        }
        var dict: [TileSpotlightItem.SpotlightSection: [TileSpotlightItem]] = [:]
        for item in filtered {
            dict[item.section, default: []].append(item)
        }
        return dict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search field row
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tc.accent)

                TextField("Search...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($queryFocused)
                    .onSubmit { executeSelected() }
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
                    .idxHitTarget()
                }

                keyBadge("esc")
                    .idxHitTarget()
                    .onTapGesture { dismiss() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)

            // Results
            if !filtered.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let flat = filtered
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                // Grouped by section
                                ForEach(groupedSections, id: \.section) { section, sectionItems in
                                    sectionHeader(section.header)
                                    ForEach(sectionItems) { item in
                                        let globalIndex = flat.firstIndex(where: { $0.id == item.id }) ?? 0
                                        spotlightRow(item: item, isSelected: globalIndex == selectedIndex)
                                            .id(item.id)
                                            .onTapGesture {
                                                selectedIndex = globalIndex
                                                executeSelected()
                                            }
                                            .onHover { hovering in
                                                guard interactionReady, hovering else { return }
                                                lastSelectionSource = .hover
                                                selectedIndex = globalIndex
                                            }
                                    }
                                }
                            } else {
                                // Flat ranked results
                                ForEach(Array(flat.enumerated()), id: \.element.id) { index, item in
                                    spotlightRow(item: item, isSelected: index == selectedIndex)
                                        .id(item.id)
                                        .onTapGesture {
                                            selectedIndex = index
                                            executeSelected()
                                        }
                                        .onHover { hovering in
                                            guard interactionReady, hovering else { return }
                                            lastSelectionSource = .hover
                                            selectedIndex = index
                                        }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .scrollIndicators(.hidden)
                    .scrollDisabled(!interactionReady)
                    .onChange(of: selectedIndex) { _, newValue in
                        guard lastSelectionSource == .keyboard else { return }
                        if let item = filtered.dropFirst(newValue).first {
                            withAnimation(.easeOut(duration: 0.08)) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        }
                    }
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(tc.tertiaryText)
                    Text("No results for \"\(query)\"")
                        .font(.system(size: 11))
                        .foregroundStyle(tc.tertiaryText)
                }
                .padding(12)
            }
        }
        .frame(width: 340)
        .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tc.surface2.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
        .onAppear {
            query = ""
            selectedIndex = 0
            interactionReady = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                queryFocused = true
            }
            // Delay mouse interaction so scroll/hover don't fire immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                interactionReady = true
            }
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Row

    @ViewBuilder
    private func spotlightRow(item: TileSpotlightItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let imageName = item.iconImageName {
                    Image(imageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: item.icon)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? tc.accent : tc.secondaryText)
            .frame(width: 24, height: 24)
            .background(
                isSelected ? tc.accent.opacity(0.1) : tc.surface1,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedTitle(item.title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tc.primaryText)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let shortcut = item.shortcut {
                keyBadge(shortcut)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? tc.surface0 : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Key Badge

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tc.surface1, in: RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Logic

    private func highlightedTitle(_ title: String) -> AttributedString {
        FuzzyMatch.highlight(query: query, in: title)
    }

    private func moveSelection(_ delta: Int) {
        let max = filtered.count - 1
        guard max >= 0 else { return }
        lastSelectionSource = .keyboard
        selectedIndex = min(max, Swift.max(0, selectedIndex + delta))
    }

    private func executeSelected() {
        guard selectedIndex < filtered.count else { return }
        let item = filtered[selectedIndex]
        dismiss()
        DispatchQueue.main.async { item.run() }
    }

    private func dismiss() {
        isPresented = false
    }
}
