import SwiftUI

// MARK: - Tile Spotlight Item

struct TileSpotlightItem: Identifiable {
    let id: String
    let icon: String
    var iconImageName: String? = nil
    let title: String
    let subtitle: String
    let searchText: String
    let run: () -> Void
}

// MARK: - Tile Spotlight Overlay

struct NiriTileSpotlight: View {
    @Environment(\.themeColors) private var tc
    @Binding var isPresented: Bool

    let items: [TileSpotlightItem]

    @FocusState private var queryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var hoveredIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tc.accent)

                TextField("Add tile...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($queryFocused)
                    .onSubmit { executeSelected() }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)

            // Results
            if !filtered.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                spotlightRow(item: item, isSelected: index == selectedIndex)
                                    .id(item.id)
                                    .onTapGesture {
                                        selectedIndex = index
                                        executeSelected()
                                    }
                                    .onHover { hovering in
                                        if hovering {
                                            hoveredIndex = index
                                            selectedIndex = index
                                        } else if hoveredIndex == index {
                                            hoveredIndex = nil
                                        }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _, newValue in
                        if let item = filtered.dropFirst(newValue).first {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(item.id, anchor: .center)
                            }
                        }
                    }
                }
            } else {
                Text("No matching tiles")
                    .font(.system(size: 11))
                    .foregroundStyle(tc.tertiaryText)
                    .padding(12)
            }

            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)

            // Footer hints
            HStack(spacing: 14) {
                keyHint("↑↓", "navigate")
                keyHint("↵", "add")
                keyHint("esc", "close")
                Spacer()
            }
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tc.windowBackground)
        }
        .frame(width: 320)
        .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tc.surface2.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
        .onAppear {
            query = ""
            selectedIndex = 0
            queryFocused = true
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
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
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(isSelected ? tc.accent : tc.secondaryText)
            .frame(width: 26, height: 26)
            .background(
                isSelected ? tc.accent.opacity(0.12) : tc.surface1,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 2) {
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? tc.surface0 : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer Key Hint

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(tc.surface1, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 9))
        }
    }

    // MARK: - Logic

    private var filtered: [TileSpotlightItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return items }
        return items.filter { item in
            FuzzyMatch.matches(query: normalized, text: item.searchText)
        }.sorted { lhs, rhs in
            FuzzyMatch.score(query: normalized, text: lhs.searchText) > FuzzyMatch.score(query: normalized, text: rhs.searchText)
        }
    }

    private func highlightedTitle(_ title: String) -> AttributedString {
        FuzzyMatch.highlight(query: query, in: title)
    }

    private func moveSelection(_ delta: Int) {
        let max = filtered.count - 1
        guard max >= 0 else { return }
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
