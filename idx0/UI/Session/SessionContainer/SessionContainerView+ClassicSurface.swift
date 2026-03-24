import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

extension SessionContainerView {
    func splitView(
        session: Session,
        terminalController: TerminalSessionController,
        browserController: SessionBrowserController,
        browserState: BrowserSurfaceState
    ) -> some View {
        GeometryReader { proxy in
            if browserState.splitSide == .right {
                let totalWidth = proxy.size.width
                let minBrowserWidth: CGFloat = 280
                let minTerminalWidth: CGFloat = 280
                let targetBrowserWidth = totalWidth * browserState.splitFraction
                let browserWidth: CGFloat = {
                    if totalWidth <= minBrowserWidth + minTerminalWidth {
                        return max(0, min(totalWidth, targetBrowserWidth))
                    }
                    return min(
                        max(minBrowserWidth, targetBrowserWidth),
                        totalWidth - minTerminalWidth
                    )
                }()
                let terminalWidth = max(0, totalWidth - browserWidth)
                HStack(spacing: 0) {
                    terminalSurface(session: session, controller: terminalController)
                        .frame(width: terminalWidth)

                    BrowserSplitResizeHandle(
                        axis: .horizontal,
                        totalSize: proxy.size.width,
                        fraction: browserState.splitFraction,
                        onFractionChanged: { fraction in
                            sessionService.setBrowserSplitFraction(for: session.id, fraction: fraction)
                        }
                    )

                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 28)
                        SessionBrowserPane(session: session, controller: browserController)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: browserWidth)
                    .transition(.move(edge: .trailing))
                }
            } else {
                let totalHeight = proxy.size.height
                let minBrowserHeight: CGFloat = 180
                let minTerminalHeight: CGFloat = 220
                let targetBrowserHeight = totalHeight * browserState.splitFraction
                let browserHeight: CGFloat = {
                    if totalHeight <= minBrowserHeight + minTerminalHeight {
                        return max(0, min(totalHeight, targetBrowserHeight))
                    }
                    return min(
                        max(minBrowserHeight, targetBrowserHeight),
                        totalHeight - minTerminalHeight
                    )
                }()
                let terminalHeight = max(0, totalHeight - browserHeight)
                VStack(spacing: 0) {
                    terminalSurface(session: session, controller: terminalController)
                        .frame(height: terminalHeight)

                    BrowserSplitResizeHandle(
                        axis: .vertical,
                        totalSize: proxy.size.height,
                        fraction: browserState.splitFraction,
                        onFractionChanged: { fraction in
                            sessionService.setBrowserSplitFraction(for: session.id, fraction: fraction)
                        }
                    )

                    SessionBrowserPane(session: session, controller: browserController)
                        .frame(height: browserHeight)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    func terminalSurface(session: Session, controller: TerminalSessionController) -> some View {
        let selectedTabID = sessionService.selectedTabID(for: session.id)
        let activeTab = selectedTabID.flatMap { tabID in
            sessionService.tabState(sessionID: session.id, tabID: tabID)
        }
        let activeControllerID = activeTab?.activeControllerID ?? controller.sessionID
        let resolvedPaneTree = activeTab?.paneTree
            ?? .terminal(id: activeControllerID, controllerID: activeControllerID)
        let resolvedFocusedControllerID = sessionService.focusedPaneControllerID[session.id]
            ?? activeTab?.focusedPaneControllerID
            ?? activeControllerID

        VStack(spacing: 0) {
            Color.clear
                .frame(height: 28)
            sessionTabStrip(sessionID: session.id)

            ZStack(alignment: .top) {
                MultiPaneTerminalView(
                    paneTree: resolvedPaneTree,
                    sessionID: session.id,
                    focusedControllerID: resolvedFocusedControllerID,
                    controllerProvider: { controllerID in
                        sessionService.ensurePaneController(for: controllerID)
                    },
                    onFocus: { controllerID in
                        sessionService.setFocusedPane(sessionID: session.id, controllerID: controllerID)
                        sessionService.markTerminalFocused(for: session.id)
                    }
                )
                .id(session.id)
                .onAppear {
                    controller.focus()
                    sessionService.markTerminalFocused(for: session.id)
                }
                .onDisappear {
                    sessionService.controllerBecameHidden(sessionID: session.id)
                }
                .onTapGesture {
                    sessionService.markTerminalFocused(for: session.id)
                }

                // Quick-approve bar (detected from terminal output)
                if let scanResult = coordinator.terminalMonitor.agentStates[session.id],
                   scanResult.hasDetectedAgent,
                   scanResult.isApprovalPrompt {
                    quickApproveBar(scanResult: scanResult, session: session, controller: controller)
                        .padding(.top, 36)
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: scanResult.isApprovalPrompt)
                }

                // Status banner
                if let statusText = session.statusText, !statusText.isEmpty {
                    statusBanner(text: statusText, sessionID: session.id, controller: controller)
                        .padding(.top, hasApprovalPrompt(for: session.id) ? 80 : 36)
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.25), value: session.statusText)
                }
            }
        }
    }

    @ViewBuilder
    func sessionTabStrip(sessionID: UUID) -> some View {
        let tabs = sessionService.tabs(for: sessionID)
        let selectedTabID = sessionService.selectedTabID(for: sessionID)

        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        let isSelected = tab.id == selectedTabID
                        Button {
                            sessionService.selectTab(sessionID: sessionID, tabID: tab.id)
                        } label: {
                            HStack(spacing: 6) {
                                Text(tab.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                if tab.paneCount > 1 {
                                    Text("\(tab.paneCount)")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tc.tertiaryText)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? tc.surface1 : tc.surface0.opacity(0.55),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .foregroundStyle(isSelected ? tc.primaryText : tc.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 10)
            }

            Button {
                sessionService.createTab(in: sessionID)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tc.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(tc.surface0.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("New Tab")

            Button {
                sessionService.closeActiveTab(in: sessionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tabs.count > 1 ? tc.secondaryText : tc.tertiaryText)
                    .frame(width: 22, height: 22)
                    .background(tc.surface0.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(tabs.count <= 1)
            .help("Close Active Tab")
            .padding(.trailing, 10)
        }
        .frame(height: 30)
        .background(tc.windowBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)
        }
    }

    // MARK: - Quick-Approve Bar

    @ViewBuilder
    func quickApproveBar(scanResult: AgentScanResult, session: Session, controller: TerminalSessionController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.8))

            Text(scanResult.approvalContext ?? "Agent needs approval")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

            Spacer(minLength: 0)

            let agent = scanResult.detectedAgent

            Button("Yes") {
                let response = agent == .codex ? "yes\n" : "y\n"
                controller.send(text: response)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)
            .tint(.green.opacity(0.7))

            Button("No") {
                let response = agent == .codex ? "no\n" : "n\n"
                controller.send(text: response)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    func hasApprovalPrompt(for sessionID: UUID) -> Bool {
        guard let result = coordinator.terminalMonitor.agentStates[sessionID] else { return false }
        return result.hasDetectedAgent && result.isApprovalPrompt
    }

    // MARK: - Status Banner

    @ViewBuilder
    func statusBanner(text: String, sessionID: UUID, controller: TerminalSessionController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.85))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

            Spacer(minLength: 0)

            if case .failedToLaunch = controller.runtimeState {
                Button("Retry") {
                    _ = sessionService.requestLaunchForActiveTerminals(
                        in: sessionID,
                        reason: .explicitAction
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            Button {
                sessionService.dismissStatusText(for: sessionID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(tc.mutedText)

            Text("No Sessions")
                .font(.title3.weight(.medium))
                .foregroundStyle(tc.secondaryText)

            Text("Press \u{2318}N for a new session or \u{2318}\u{2325}N to set up a project")
                .font(.system(size: 11))
                .foregroundStyle(tc.tertiaryText)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    coordinator.sessionService.createQuickSession()
                } label: {
                    Text("New Session")
                        .font(.callout)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    openFolderAndCreateSession()
                } label: {
                    Text("Open Folder")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func openFolderAndCreateSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        errorMessage = nil

        Task {
            do {
                _ = try await sessionService.createSession(from: SessionCreationRequest(
                    title: nil,
                    repoPath: folder,
                    createWorktree: false,
                    branchName: nil,
                    existingWorktreePath: nil,
                    shellPath: nil
                ))
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
