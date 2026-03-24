import SwiftUI
import WebKit

struct BrowserToolbar: View {
    @EnvironmentObject private var sessionService: SessionService
    @ObservedObject var controller: SessionBrowserController
    @ObservedObject private var dataStore = BrowserDataStore.shared
    @Environment(\.themeColors) private var tc

    let sessionID: UUID
    @Binding var addressBar: String

    var showSplitControls: Bool = false
    var splitSide: SplitSide? = nil
    var onToggleSplitSide: (() -> Void)? = nil
    var onCloseSplit: (() -> Void)? = nil

    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var showSuggestions = false
    @State private var suggestions: [SuggestionItem] = []
    @State private var findQuery = ""

    private enum SuggestionItem: Identifiable {
        case bookmark(BrowserBookmark)
        case history(BrowserHistoryEntry)

        var id: String {
            switch self {
            case .bookmark(let b): return "b-\(b.id)"
            case .history(let h): return "h-\(h.id)"
            }
        }
        var title: String {
            switch self {
            case .bookmark(let b): return b.title
            case .history(let h): return h.title
            }
        }
        var url: String {
            switch self {
            case .bookmark(let b): return b.url
            case .history(let h): return h.url
            }
        }
        var isBookmark: Bool {
            if case .bookmark = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main toolbar row
            HStack(spacing: 8) {
                navigationButtons
                addressBarField
                toolbarActions
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tc.surface0)

            // Loading progress bar
            if controller.isLoading {
                GeometryReader { geo in
                    Rectangle()
                        .fill(tc.accent)
                        .frame(width: geo.size.width * controller.estimatedProgress, height: 2)
                        .animation(.linear(duration: 0.2), value: controller.estimatedProgress)
                }
                .frame(height: 2)
            }

            // Error banner
            if let error = controller.navigationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 10))
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(tc.secondaryText)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        controller.reload()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button {
                        controller.navigationError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tc.surface1)
            }

            // Find bar
            if controller.isFindBarVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(tc.secondaryText)
                    TextField("Find in page…", text: $findQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit {
                            controller.findInPage(findQuery)
                        }
                    Button("Next") {
                        controller.findInPage(findQuery)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    Button {
                        findQuery = ""
                        controller.dismissFind()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(tc.surface1)
            }

            // Suggestions dropdown
            if showSuggestions && !suggestions.isEmpty {
                suggestionsView
            }
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            Button { controller.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .idxHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoBack)
            .opacity(controller.canGoBack ? 1 : 0.35)
            .help("Back")

            Button { controller.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .idxHitTarget()
            }
            .buttonStyle(.plain)
            .disabled(!controller.canGoForward)
            .opacity(controller.canGoForward ? 1 : 0.35)
            .help("Forward")

            if controller.isLoading {
                Button { controller.stopLoading() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .idxHitTarget()
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button { controller.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                        .idxHitTarget()
                }
                .buttonStyle(.plain)
                .help("Reload")
            }
        }
    }

    // MARK: - Address Bar

    private var addressBarField: some View {
        HStack(spacing: 6) {
            if controller.isSecure {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(tc.tertiaryText)
            }
            TextField(controller.pageTitle ?? "Search or enter URL", text: $addressBar)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onChange(of: addressBar) { _, newValue in
                    updateSuggestions(for: newValue)
                }
                .onSubmit {
                    showSuggestions = false
                    sessionService.markBrowserFocused(for: sessionID)
                    controller.load(urlString: addressBar)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tc.surface1.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Toolbar Actions

    private var toolbarActions: some View {
        HStack(spacing: 2) {
            // Bookmark toggle
            Button {
                toggleBookmark()
            } label: {
                Image(systemName: dataStore.isBookmarked(url: controller.currentURLString) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(dataStore.isBookmarked(url: controller.currentURLString) ? .yellow : tc.secondaryText)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dataStore.isBookmarked(url: controller.currentURLString) ? "Remove Bookmark" : "Add Bookmark")

            // Share / open externally
            Button {
                controller.openInDefaultBrowser()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tc.secondaryText)
            .help("Open in Browser")

            // Overflow menu for bookmarks, history, find, zoom
            Menu {
                Button {
                    showBookmarks.toggle()
                } label: {
                    Label("Bookmarks", systemImage: "book")
                }

                Button {
                    showHistory.toggle()
                } label: {
                    Label("History", systemImage: "clock")
                }

                Divider()

                Button {
                    controller.isFindBarVisible.toggle()
                    if !controller.isFindBarVisible {
                        findQuery = ""
                        controller.dismissFind()
                    }
                } label: {
                    Label("Find in Page", systemImage: "magnifyingglass")
                }

                Divider()

                Button { adjustZoom(by: 0.1) } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                Button { adjustZoom(by: -0.1) } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                Button { controller.webView.pageZoom = 1.0 } label: {
                    Label("Reset Zoom", systemImage: "1.magnifyingglass")
                }

                if showSplitControls {
                    Divider()
                    if let onToggleSplitSide {
                        Button {
                            sessionService.markBrowserFocused(for: sessionID)
                            onToggleSplitSide()
                        } label: {
                            Label("Toggle Split Side", systemImage: "rectangle.split.2x1")
                        }
                    }
                    if let onCloseSplit {
                        Button {
                            onCloseSplit()
                        } label: {
                            Label("Close Split", systemImage: "xmark.rectangle")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
            .foregroundStyle(tc.secondaryText)
            .help("More")
        }
        .popover(isPresented: $showBookmarks) {
            bookmarksPopover
        }
        .popover(isPresented: $showHistory) {
            historyPopover
        }
    }

    // MARK: - Bookmarks Popover

    private var bookmarksPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bookmarks")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            if dataStore.bookmarks.isEmpty {
                Text("No bookmarks yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dataStore.bookmarks) { bookmark in
                            Button {
                                addressBar = bookmark.url
                                controller.load(urlString: bookmark.url)
                                showBookmarks = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(bookmark.url)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove") {
                                    dataStore.removeBookmark(id: bookmark.id)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 280)
        .padding(.bottom, 8)
    }

    // MARK: - History Popover

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !dataStore.history.isEmpty {
                    Button("Clear") {
                        dataStore.clearHistory()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(tc.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if dataStore.history.isEmpty {
                Text("No history")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dataStore.history.prefix(50)) { entry in
                            Button {
                                addressBar = entry.url
                                controller.load(urlString: entry.url)
                                showHistory = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    HStack {
                                        Text(entry.url)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(entry.visitedAt, style: .relative)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 320)
        .padding(.bottom, 8)
    }

    // MARK: - Suggestions

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { item in
                Button {
                    addressBar = item.url
                    showSuggestions = false
                    controller.load(urlString: item.url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.isBookmark ? "star.fill" : "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(item.isBookmark ? .yellow : tc.tertiaryText)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Text(item.url)
                                .font(.system(size: 9))
                                .foregroundStyle(tc.tertiaryText)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(tc.surface1)
    }

    // MARK: - Helpers

    private func toggleBookmark() {
        guard let url = controller.currentURLString, !url.isEmpty else { return }
        if dataStore.isBookmarked(url: url) {
            dataStore.removeBookmark(url: url)
        } else {
            let title = controller.pageTitle ?? url
            dataStore.addBookmark(title: title, url: url)
        }
    }

    private func adjustZoom(by delta: CGFloat) {
        let current = controller.webView.pageZoom
        let newZoom = max(0.5, min(3.0, current + delta))
        controller.webView.pageZoom = newZoom
    }

    private func updateSuggestions(for query: String) {
        guard query.count >= 2 else {
            suggestions = []
            showSuggestions = false
            return
        }
        let bookmarkResults = dataStore.bookmarkSuggestions(for: query).map { SuggestionItem.bookmark($0) }
        let historyResults = dataStore.historySuggestions(for: query).map { SuggestionItem.history($0) }

        var seen = Set<String>()
        var merged: [SuggestionItem] = []
        for item in bookmarkResults + historyResults {
            if !seen.contains(item.url) {
                seen.insert(item.url)
                merged.append(item)
            }
            if merged.count >= 8 { break }
        }
        suggestions = merged
        showSuggestions = !merged.isEmpty
    }
}
