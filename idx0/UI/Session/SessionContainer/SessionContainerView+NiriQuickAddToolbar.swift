import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func niriCanvasToolbar(sessionID: UUID, layout: NiriCanvasLayout) -> some View {
        let activeWorkspace = niriActiveWorkspaceIndex(layout: layout).map { $0 + 1 } ?? 1
        let activeColumn = niriActiveColumnIndex(
            layout: layout,
            workspaceIndex: niriActiveWorkspaceIndex(layout: layout) ?? 0
        ).map { $0 + 1 } ?? 1

        return HStack(spacing: 8) {
            Text("w\(activeWorkspace) · c\(activeColumn)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(tc.tertiaryText)

            if layout.isOverviewOpen {
                Text("Overview")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tc.accent.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tc.accent.opacity(0.1), in: Capsule())
            }

            if sessionService.settings.niri.snapEnabled {
                Text("Snap")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tc.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tc.surface1.opacity(0.8), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(tc.windowBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    func niriCanvasQuickAddButton(sessionID: UUID) -> some View {
        Button {
            niriQuickAddMenuPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(niriQuickAddMenuPresented ? tc.accent : tc.primaryText)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(niriQuickAddMenuPresented ? tc.accent.opacity(0.15) : tc.surface1.opacity(0.95))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            niriQuickAddMenuPresented ? tc.accent.opacity(0.4) : tc.divider.opacity(0.9),
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
        .help("Add Tile (\(niriAddTileShortcutLabel))")
        .animation(.easeOut(duration: 0.12), value: niriQuickAddMenuPresented)
    }

    /// Spotlight overlay placed at the canvas surface level for proper full-area coverage.
    @ViewBuilder
    func niriTileSpotlightOverlay(sessionID: UUID) -> some View {
        if niriQuickAddMenuPresented {
            ZStack(alignment: .topLeading) {
                // Dim backdrop
                Color.black.opacity(0.3)
                    .contentShape(Rectangle())
                    .onTapGesture { niriQuickAddMenuPresented = false }

                // Spotlight positioned near the + button
                NiriTileSpotlight(
                    isPresented: $niriQuickAddMenuPresented,
                    items: niriSpotlightItems(sessionID: sessionID)
                )
                .padding(.top, 74) // below toolbar (28) + button area (38) + gap (8)
                .padding(.leading, 10)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Spotlight Items

    func niriSpotlightItems(sessionID: UUID) -> [TileSpotlightItem] {
        var items: [TileSpotlightItem] = []

        // Terminal tile (always first)
        items.append(TileSpotlightItem(
            id: "terminal",
            icon: "terminal",
            title: "Terminal",
            subtitle: "New terminal tile",
            searchText: "terminal shell console bash zsh",
            run: {
                _ = self.sessionService.niriAddTerminalRight(in: sessionID)
            }
        ))

        // Registered apps
        let visibleApps = NiriAppUIVisibility.quickAddApps(from: sessionService.registeredNiriApps)
        for app in visibleApps {
            items.append(TileSpotlightItem(
                id: "app-\(app.id)",
                icon: app.icon,
                iconImageName: app.iconImageName,
                title: app.displayName,
                subtitle: app.menuSubtitle,
                searchText: "\(app.displayName.lowercased()) \(app.id) \(app.menuSubtitle.lowercased()) app tile",
                run: {
                    _ = self.sessionService.niriAddAppRight(in: sessionID, appID: app.id)
                }
            ))
        }

        // Browser tile
        items.append(TileSpotlightItem(
            id: "browser",
            icon: "globe",
            title: "Browser",
            subtitle: "Open web view tile",
            searchText: "browser web view globe url http",
            run: {
                _ = self.sessionService.niriAddBrowserRight(in: sessionID)
            }
        ))

        // Agentic CLIs
        let installedTools = workflowService.vibeTools.filter(\.isInstalled)
        for tool in installedTools {
            items.append(TileSpotlightItem(
                id: "tool-\(tool.id)",
                icon: niriToolIconName(for: tool.id),
                title: tool.displayName,
                subtitle: tool.executableName,
                searchText: "\(tool.displayName.lowercased()) \(tool.executableName.lowercased()) cli agent agentic tool",
                run: {
                    self.niriLaunchToolInNewTile(sessionID: sessionID, toolID: tool.id)
                }
            ))
        }

        return items
    }

    private var niriAddTileShortcutLabel: String {
        ShortcutRegistry.shared.displayLabel(
            for: .niriOpenAddTileMenu,
            settings: sessionService.settings
        ) ?? "+"
    }

    func niriLaunchToolInNewTile(sessionID: UUID, toolID: String) {
        guard sessionService.sessions.contains(where: { $0.id == sessionID }) else { return }
        _ = sessionService.niriAddTerminalRight(in: sessionID)
        do {
            try workflowService.launchTool(toolID, in: sessionID)
        } catch {
            sessionService.postStatusMessage(error.localizedDescription, for: sessionID)
        }
    }

    func niriToolIconName(for toolID: String) -> String {
        switch toolID {
        case "claude":
            return "text.bubble"
        case "codex":
            return "terminal"
        case "gemini-cli":
            return "sparkles"
        case "opencode":
            return "chevron.left.forwardslash.chevron.right"
        case "droid":
            return "cpu"
        default:
            return "terminal"
        }
    }

}
