import SwiftUI

// MARK: - Notification for tracking performed actions

extension Notification.Name {
    static let niriOnboardingActionPerformed = Notification.Name("niriOnboardingActionPerformed")
}

// MARK: - Onboarding Step Model

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case keybindingChoice
    case addTileRight
    case focusLeft
    case focusRight
    case addTaskBelow
    case overview
    case closeTile
    case complete

    var title: String {
        switch self {
        case .welcome: return "Welcome to Niri Canvas"
        case .keybindingChoice: return "Choose Your Style"
        case .addTileRight: return "Add a Terminal"
        case .focusLeft: return "Move Focus Left"
        case .focusRight: return "Move Focus Right"
        case .addTaskBelow: return "Stack a Tile Below"
        case .overview: return "Open Overview"
        case .closeTile: return "Close a Tile"
        case .complete: return "You\u{2019}re Ready!"
        }
    }

    var instruction: String {
        switch self {
        case .welcome:
            return "Niri Canvas is a scrolling tiling workspace. Your terminals live on an infinite horizontal canvas.\n\nThis walkthrough will teach you the basics using a practice canvas."
        case .keybindingChoice:
            return "First, pick the keybinding style that fits your workflow. This controls which shortcuts appear in the next steps."
        case .addTileRight:
            return "Add a new terminal column to the right of the focused tile.\n\nNiri-native shortcut: Mod+T."
        case .focusLeft:
            return "Move your focus back to the tile on the left."
        case .focusRight:
            return "Move focus to the tile you just created on the right."
        case .addTaskBelow:
            return "Stack a new tile below the focused tile in the same column."
        case .overview:
            return "Open Overview to see all your tiles at a bird\u{2019}s-eye view."
        case .closeTile:
            return "Close the currently focused tile to clean up.\n\nNiri-native shortcut: Mod+W."
        case .complete:
            return "You\u{2019}ve mastered the basics! Swipe your trackpad to pan, and use workspaces to organize vertically."
        }
    }

    var requiredAction: ShortcutActionID? {
        switch self {
        case .addTileRight: return .niriAddTerminalRight
        case .focusLeft: return .niriFocusLeft
        case .focusRight: return .niriFocusRight
        case .addTaskBelow: return .niriAddTaskBelow
        case .overview: return .niriToggleOverview
        case .closeTile: return .closePane
        default: return nil
        }
    }

    var alternateActions: [ShortcutActionID] {
        switch self {
        case .addTileRight: return [.splitRight]
        case .addTaskBelow: return [.splitDown]
        default: return []
        }
    }

    var isInteractive: Bool { requiredAction != nil }

    var stepNumber: Int? {
        switch self {
        case .welcome, .complete: return nil
        case .keybindingChoice: return 1
        case .addTileRight: return 2
        case .focusLeft: return 3
        case .focusRight: return 4
        case .addTaskBelow: return 5
        case .overview: return 6
        case .closeTile: return 7
        }
    }

    static var interactiveStepCount: Int { 7 }
}

// MARK: - Dummy Tile Model

private struct DummyTile: Identifiable, Equatable {
    let id: UUID
    var label: String
    var icon: String
}

private struct DummyColumn: Identifiable, Equatable {
    let id: UUID
    var items: [DummyTile]
}

// MARK: - Coaching Overlay

struct NiriOnboardingOverlay: View {
    @Environment(\.themeColors) private var tc
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService

    @State private var currentStep: OnboardingStep = .welcome
    @State private var showSuccess = false
    @State private var selectedMode: KeybindingMode?
    @State private var isOverviewMode = false

    // Dummy canvas state
    @State private var columns: [DummyColumn] = [
        DummyColumn(id: UUID(), items: [
            DummyTile(id: UUID(), label: "Terminal 1", icon: "terminal")
        ])
    ]
    @State private var focusedTileID: UUID?
    @State private var focusedColumnIndex: Int = 0

    private let registry = ShortcutRegistry.shared
    private var tileCounter: Int { columns.flatMap(\.items).count }

    var body: some View {
        ZStack {
            // Dim background — blocks all interaction with the canvas behind
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    Rectangle()
                        .fill(tc.divider)
                        .frame(height: 1)

                    // Mini canvas (hidden for welcome and keybinding choice)
                    if currentStep != .welcome && currentStep != .keybindingChoice {
                        miniCanvas
                            .frame(maxWidth: .infinity)
                            .frame(height: 260)
                            .background(tc.windowBackground)

                        Rectangle()
                            .fill(tc.divider)
                            .frame(height: 1)
                    }

                    // Coaching area
                    coachingArea
                        .padding(16)
                }
                .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(tc.surface2.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .frame(maxWidth: 680)
                .padding(30)
            }
        }
        .onAppear {
            focusedTileID = columns.first?.items.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .niriOnboardingActionPerformed)) { notification in
            guard let actionRaw = notification.userInfo?["action"] as? String,
                  let action = ShortcutActionID(rawValue: actionRaw) else { return }
            handleAction(action)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let stepNum = currentStep.stepNumber {
                    Text("STEP \(stepNum) OF \(OnboardingStep.interactiveStepCount)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(tc.accent)
                }
                Text(currentStep.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tc.primaryText)
            }

            Spacer()

            if showSuccess {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                    Text("Done!")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
            }

            // Progress dots
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step == currentStep ? tc.accent : (step.rawValue < currentStep.rawValue ? tc.secondaryText : tc.surface2))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.leading, 8)
        }
    }

    // MARK: - Mini Canvas

    private var miniCanvas: some View {
        GeometryReader { geo in
            ZStack {
                if isOverviewMode {
                    overviewCanvas(in: geo.size)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    normalCanvas(in: geo.size)
                        .transition(.scale(scale: 1.2).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35, bounce: 0.1), value: isOverviewMode)
        }
        .clipped()
    }

    private func normalCanvas(in size: CGSize) -> some View {
        let spacing: CGFloat = 14
        let tileWidthBase: CGFloat = max(140, min(200, (size.width - CGFloat(columns.count + 1) * spacing) / max(1, CGFloat(columns.count))))

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(columns) { column in
                        VStack(spacing: 8) {
                            ForEach(column.items) { tile in
                                dummyTileView(
                                    tile: tile,
                                    isFocused: tile.id == focusedTileID,
                                    width: tileWidthBase,
                                    height: column.items.count > 1
                                        ? max(80, (size.height - 40 - CGFloat(column.items.count - 1) * 8) / CGFloat(column.items.count))
                                        : size.height - 40
                                )
                            }
                        }
                        .id(column.id)
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.vertical, 20)
            }
            .onChange(of: focusedColumnIndex) { _, newIndex in
                if newIndex < columns.count {
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                        proxy.scrollTo(columns[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func overviewCanvas(in size: CGSize) -> some View {
        let totalTiles = columns.flatMap(\.items).count
        let scale: CGFloat = max(0.35, min(0.7, 5.0 / CGFloat(max(1, totalTiles))))
        let tileW: CGFloat = 160 * scale
        let spacing: CGFloat = 10 * scale

        return HStack(alignment: .top, spacing: spacing) {
            ForEach(columns) { column in
                VStack(spacing: 6 * scale) {
                    ForEach(column.items) { tile in
                        dummyTileView(
                            tile: tile,
                            isFocused: tile.id == focusedTileID,
                            width: tileW,
                            height: 100 * scale
                        )
                        .scaleEffect(scale < 0.5 ? 0.9 : 1.0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.15))
    }

    private func dummyTileView(tile: DummyTile, isFocused: Bool, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: tile.icon)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isFocused ? tc.accent : tc.tertiaryText)
                Text(tile.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isFocused ? tc.primaryText : tc.secondaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(tc.tertiaryText)
                    .opacity(isFocused ? 0.8 : 0.3)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tc.surface0.opacity(0.6))

            // Body - fake terminal lines
            VStack(alignment: .leading, spacing: 3) {
                fakeTerminalLine(width: 0.7, color: tc.accent.opacity(0.4))
                fakeTerminalLine(width: 0.5, color: tc.tertiaryText.opacity(0.3))
                fakeTerminalLine(width: 0.85, color: tc.tertiaryText.opacity(0.2))
                if height > 100 {
                    fakeTerminalLine(width: 0.4, color: tc.tertiaryText.opacity(0.15))
                    fakeTerminalLine(width: 0.6, color: tc.tertiaryText.opacity(0.1))
                }
                Spacer()
                // Fake prompt
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tc.accent.opacity(isFocused ? 0.5 : 0.2))
                        .frame(width: 20, height: 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tc.tertiaryText.opacity(0.2))
                        .frame(width: 6, height: 8)
                        .opacity(isFocused ? 1 : 0)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isFocused ? tc.contentBackground : tc.surface0.opacity(0.3))
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? tc.accent.opacity(0.5) : tc.divider.opacity(0.5), lineWidth: isFocused ? 1.5 : 0.5)
        )
        .shadow(color: isFocused ? tc.accent.opacity(0.12) : .clear, radius: isFocused ? 6 : 0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private func fakeTerminalLine(width fraction: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: geo.size.width * fraction, height: 3)
        }
        .frame(height: 3)
    }

    // MARK: - Coaching Area

    private var coachingArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentStep.instruction)
                .font(.system(size: 12))
                .foregroundStyle(tc.secondaryText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let action = currentStep.requiredAction {
                shortcutHint(for: action)
            }

            if currentStep == .keybindingChoice {
                keybindingCards
            }

            actionButtons
        }
    }

    // MARK: - Shortcut Hint

    private func shortcutHint(for action: ShortcutActionID) -> some View {
        let label = registry.displayLabel(for: action, settings: settingsForDisplay) ?? "Unassigned"

        return HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 11))
                .foregroundStyle(tc.accent)
                .frame(width: 18)

            Text("Press")
                .font(.system(size: 11))
                .foregroundStyle(tc.tertiaryText)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tc.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(tc.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))

            Spacer()

            Button("or click here") {
                performStepAction()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(tc.tertiaryText)
            .underline()
        }
        .padding(10)
        .background(tc.surface0, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Keybinding Choice

    private var keybindingCards: some View {
        VStack(spacing: 6) {
            keybindingOption(mode: .both, title: "Both (Recommended)", subtitle: "Arrows and H/J/K/L both work")
            keybindingOption(mode: .macOSFirst, title: "macOS-style", subtitle: "Arrow keys with Cmd+Option")
            keybindingOption(mode: .niriFirst, title: "Vim / Niri-style", subtitle: "H/J/K/L with Cmd+Option")
        }
    }

    private func keybindingOption(mode: KeybindingMode, title: String, subtitle: String) -> some View {
        let isSelected = (selectedMode ?? sessionService.settings.keybindingMode) == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedMode = mode }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? tc.accent : tc.surface2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(tc.primaryText)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(tc.tertiaryText)
                }
                Spacer()
            }
            .padding(10)
            .background(isSelected ? tc.accent.opacity(0.08) : tc.surface0, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? tc.accent.opacity(0.3) : tc.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Button("Skip Tutorial") { finishOnboarding() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(tc.tertiaryText)

            Spacer()

            if currentStep == .welcome {
                Button("Let\u{2019}s Go") { advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else if currentStep == .keybindingChoice {
                Button("Next") {
                    if let mode = selectedMode { sessionService.saveSettings { $0.keybindingMode = mode } }
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else if currentStep == .complete {
                Button("View All Shortcuts") { coordinator.showingKeyboardShortcuts = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Finish") { finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Canvas Manipulation (Dummy)

    private func performStepAction() {
        guard currentStep.isInteractive else { return }

        switch currentStep {
        case .addTileRight: dummyAddTileRight()
        case .focusLeft: dummyFocusLeft()
        case .focusRight: dummyFocusRight()
        case .addTaskBelow: dummyAddTaskBelow()
        case .overview: dummyToggleOverview()
        case .closeTile: dummyCloseTile()
        default: break
        }

        withAnimation { showSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            showSuccess = false
            advance()
        }
    }

    private func dummyAddTileRight() {
        let newTile = DummyTile(id: UUID(), label: "Terminal \(tileCounter + 1)", icon: "terminal")
        let insertIndex = focusedColumnIndex + 1
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            columns.insert(DummyColumn(id: UUID(), items: [newTile]), at: min(insertIndex, columns.count))
            focusedTileID = newTile.id
            focusedColumnIndex = min(insertIndex, columns.count - 1)
        }
    }

    private func dummyFocusLeft() {
        guard focusedColumnIndex > 0 else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            focusedColumnIndex -= 1
            focusedTileID = columns[focusedColumnIndex].items.first?.id
        }
    }

    private func dummyFocusRight() {
        guard focusedColumnIndex + 1 < columns.count else { return }
        withAnimation(.spring(duration: 0.25, bounce: 0)) {
            focusedColumnIndex += 1
            focusedTileID = columns[focusedColumnIndex].items.first?.id
        }
    }

    private func dummyAddTaskBelow() {
        guard focusedColumnIndex < columns.count else { return }
        let newTile = DummyTile(id: UUID(), label: "Terminal \(tileCounter + 1)", icon: "terminal")
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            columns[focusedColumnIndex].items.append(newTile)
            focusedTileID = newTile.id
        }
    }

    private func dummyToggleOverview() {
        withAnimation(.spring(duration: 0.35, bounce: 0.08)) {
            isOverviewMode.toggle()
        }
    }

    private func dummyCloseTile() {
        guard focusedColumnIndex < columns.count else { return }
        let col = columns[focusedColumnIndex]
        guard let tileIdx = col.items.firstIndex(where: { $0.id == focusedTileID }) else { return }

        withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
            columns[focusedColumnIndex].items.remove(at: tileIdx)
            if columns[focusedColumnIndex].items.isEmpty {
                columns.remove(at: focusedColumnIndex)
                focusedColumnIndex = max(0, min(focusedColumnIndex, columns.count - 1))
            }
            if focusedColumnIndex < columns.count {
                focusedTileID = columns[focusedColumnIndex].items.first?.id
            }
        }
    }

    // MARK: - Action Handling from real shortcuts

    private func handleAction(_ action: ShortcutActionID) {
        guard currentStep.isInteractive else { return }
        let matches = action == currentStep.requiredAction || currentStep.alternateActions.contains(action)
        guard matches else { return }
        performStepAction()
    }

    private func advance() {
        let allSteps = OnboardingStep.allCases
        guard let idx = allSteps.firstIndex(of: currentStep),
              idx + 1 < allSteps.count else {
            finishOnboarding()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentStep = allSteps[idx + 1]
        }
    }

    private func finishOnboarding() {
        coordinator.showingNiriOnboarding = false
        sessionService.saveSettings { $0.hasSeenNiriOnboarding = true }
    }

    private var settingsForDisplay: AppSettings {
        if let mode = selectedMode {
            var s = sessionService.settings
            s.keybindingMode = mode
            return s
        }
        return sessionService.settings
    }
}

// MARK: - Legacy sheet wrapper

struct NiriOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColors) private var tc
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var sessionService: SessionService

    var body: some View {
        NiriOnboardingOverlay()
            .environmentObject(coordinator)
            .environmentObject(sessionService)
            .frame(width: 680, height: 560)
            .background(tc.windowBackground)
    }
}
