import Foundation

enum RestoreBehavior: String, Codable, CaseIterable {
    case restoreMetadataOnly
    case relaunchSelectedSession
    case relaunchAllSessions

    var displayLabel: String {
        switch self {
        case .restoreMetadataOnly:
            return "Restore Metadata Only"
        case .relaunchSelectedSession:
            return "Relaunch Selected Session"
        case .relaunchAllSessions:
            return "Relaunch All Sessions"
        }
    }
}

enum ExternalLinkRouting: String, Codable, CaseIterable {
    case defaultBrowser
    case embeddedBrowser

    var displayLabel: String {
        switch self {
        case .defaultBrowser:
            return "Default Browser"
        case .embeddedBrowser:
            return "Embedded Browser"
        }
    }
}

enum NewSessionBehavior: String, Codable, CaseIterable {
    case quick
    case structured

    var displayLabel: String {
        switch self {
        case .quick:
            return "Quick Session"
        case .structured:
            return "Structured Setup"
        }
    }
}

enum AppMode: String, Codable, CaseIterable {
    case terminal
    case hybrid
    case vibeStudio

    var displayLabel: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .hybrid:
            return "Hybrid"
        case .vibeStudio:
            return "Vibe Studio"
        }
    }

    var showsVibeFeatures: Bool {
        self != .terminal
    }

    var showsWorkflowRail: Bool {
        self == .vibeStudio
    }
}

enum NiriHotCorner: String, Codable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct NiriEdgeViewScrollSettings: Codable, Equatable {
    var triggerWidth: Double
    var delayMs: Int
    var maxSpeed: Double

    init(
        triggerWidth: Double = 30,
        delayMs: Int = 100,
        maxSpeed: Double = 1500
    ) {
        self.triggerWidth = triggerWidth
        self.delayMs = delayMs
        self.maxSpeed = maxSpeed
    }
}

struct NiriEdgeWorkspaceSwitchSettings: Codable, Equatable {
    var triggerHeight: Double
    var delayMs: Int
    var maxSpeed: Double

    init(
        triggerHeight: Double = 50,
        delayMs: Int = 100,
        maxSpeed: Double = 1500
    ) {
        self.triggerHeight = triggerHeight
        self.delayMs = delayMs
        self.maxSpeed = maxSpeed
    }
}

struct NiriGestureSettings: Codable, Equatable {
    var decisionThresholdPx: Double
    var swipeHistoryMs: Int
    var decelerationTouchpad: Double
    var snapVelocityThresholdPxPerSec: Double
    var horizontalSpringStiffness: Double
    var horizontalSpringDamping: Double
    var verticalSpringStiffness: Double
    var verticalSpringDamping: Double

    init(
        decisionThresholdPx: Double = 16,
        swipeHistoryMs: Int = 150,
        decelerationTouchpad: Double = 0.997,
        snapVelocityThresholdPxPerSec: Double = 900,
        horizontalSpringStiffness: Double = 800,
        horizontalSpringDamping: Double = 1.0,
        verticalSpringStiffness: Double = 1000,
        verticalSpringDamping: Double = 1.0
    ) {
        self.decisionThresholdPx = decisionThresholdPx
        self.swipeHistoryMs = swipeHistoryMs
        self.decelerationTouchpad = decelerationTouchpad
        self.snapVelocityThresholdPxPerSec = snapVelocityThresholdPxPerSec
        self.horizontalSpringStiffness = horizontalSpringStiffness
        self.horizontalSpringDamping = horizontalSpringDamping
        self.verticalSpringStiffness = verticalSpringStiffness
        self.verticalSpringDamping = verticalSpringDamping
    }

    private enum CodingKeys: String, CodingKey {
        case decisionThresholdPx
        case swipeHistoryMs
        case decelerationTouchpad
        case snapVelocityThresholdPxPerSec
        case horizontalSpringStiffness
        case horizontalSpringDamping
        case verticalSpringStiffness
        case verticalSpringDamping
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decisionThresholdPx = try container.decodeIfPresent(Double.self, forKey: .decisionThresholdPx) ?? 16
        swipeHistoryMs = try container.decodeIfPresent(Int.self, forKey: .swipeHistoryMs) ?? 150
        decelerationTouchpad = try container.decodeIfPresent(Double.self, forKey: .decelerationTouchpad) ?? 0.997
        snapVelocityThresholdPxPerSec = try container.decodeIfPresent(Double.self, forKey: .snapVelocityThresholdPxPerSec) ?? 900
        horizontalSpringStiffness = try container.decodeIfPresent(Double.self, forKey: .horizontalSpringStiffness) ?? 800
        horizontalSpringDamping = try container.decodeIfPresent(Double.self, forKey: .horizontalSpringDamping) ?? 1.0
        verticalSpringStiffness = try container.decodeIfPresent(Double.self, forKey: .verticalSpringStiffness) ?? 1000
        verticalSpringDamping = try container.decodeIfPresent(Double.self, forKey: .verticalSpringDamping) ?? 1.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decisionThresholdPx, forKey: .decisionThresholdPx)
        try container.encode(swipeHistoryMs, forKey: .swipeHistoryMs)
        try container.encode(decelerationTouchpad, forKey: .decelerationTouchpad)
        try container.encode(snapVelocityThresholdPxPerSec, forKey: .snapVelocityThresholdPxPerSec)
        try container.encode(horizontalSpringStiffness, forKey: .horizontalSpringStiffness)
        try container.encode(horizontalSpringDamping, forKey: .horizontalSpringDamping)
        try container.encode(verticalSpringStiffness, forKey: .verticalSpringStiffness)
        try container.encode(verticalSpringDamping, forKey: .verticalSpringDamping)
    }
}

struct NiriSettings: Codable, Equatable {
    var snapEnabled: Bool
    var resizeCameraVisualizerEnabled: Bool
    var gestures: NiriGestureSettings
    var edgeViewScroll: NiriEdgeViewScrollSettings
    var edgeWorkspaceSwitch: NiriEdgeWorkspaceSwitchSettings
    var hotCorners: [NiriHotCorner]
    var defaultColumnDisplayMode: NiriColumnDisplayMode
    var defaultNewColumnWidth: Double?
    var defaultNewTileHeight: Double?

    init(
        snapEnabled: Bool = true,
        resizeCameraVisualizerEnabled: Bool = true,
        gestures: NiriGestureSettings = NiriGestureSettings(),
        edgeViewScroll: NiriEdgeViewScrollSettings = NiriEdgeViewScrollSettings(),
        edgeWorkspaceSwitch: NiriEdgeWorkspaceSwitchSettings = NiriEdgeWorkspaceSwitchSettings(),
        hotCorners: [NiriHotCorner] = [.topLeft],
        defaultColumnDisplayMode: NiriColumnDisplayMode = .normal,
        defaultNewColumnWidth: Double? = nil,
        defaultNewTileHeight: Double? = nil
    ) {
        self.snapEnabled = snapEnabled
        self.resizeCameraVisualizerEnabled = resizeCameraVisualizerEnabled
        self.gestures = gestures
        self.edgeViewScroll = edgeViewScroll
        self.edgeWorkspaceSwitch = edgeWorkspaceSwitch
        self.hotCorners = hotCorners
        self.defaultColumnDisplayMode = defaultColumnDisplayMode
        self.defaultNewColumnWidth = defaultNewColumnWidth
        self.defaultNewTileHeight = defaultNewTileHeight
    }

    private enum CodingKeys: String, CodingKey {
        case snapEnabled
        case resizeCameraVisualizerEnabled
        case gestures
        case edgeViewScroll
        case edgeWorkspaceSwitch
        case hotCorners
        case defaultColumnDisplayMode
        case defaultNewColumnWidth
        case defaultNewTileHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapEnabled = try container.decodeIfPresent(Bool.self, forKey: .snapEnabled) ?? true
        resizeCameraVisualizerEnabled = try container.decodeIfPresent(Bool.self, forKey: .resizeCameraVisualizerEnabled) ?? true
        gestures = try container.decodeIfPresent(NiriGestureSettings.self, forKey: .gestures) ?? NiriGestureSettings()
        edgeViewScroll = try container.decodeIfPresent(NiriEdgeViewScrollSettings.self, forKey: .edgeViewScroll) ?? NiriEdgeViewScrollSettings()
        edgeWorkspaceSwitch = try container.decodeIfPresent(NiriEdgeWorkspaceSwitchSettings.self, forKey: .edgeWorkspaceSwitch) ?? NiriEdgeWorkspaceSwitchSettings()
        hotCorners = try container.decodeIfPresent([NiriHotCorner].self, forKey: .hotCorners) ?? [.topLeft]
        defaultColumnDisplayMode = try container.decodeIfPresent(NiriColumnDisplayMode.self, forKey: .defaultColumnDisplayMode) ?? .normal
        defaultNewColumnWidth = Self.clampWidth(
            try container.decodeIfPresent(Double.self, forKey: .defaultNewColumnWidth)
        )
        defaultNewTileHeight = Self.clampHeight(
            try container.decodeIfPresent(Double.self, forKey: .defaultNewTileHeight)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snapEnabled, forKey: .snapEnabled)
        try container.encode(resizeCameraVisualizerEnabled, forKey: .resizeCameraVisualizerEnabled)
        try container.encode(gestures, forKey: .gestures)
        try container.encode(edgeViewScroll, forKey: .edgeViewScroll)
        try container.encode(edgeWorkspaceSwitch, forKey: .edgeWorkspaceSwitch)
        try container.encode(hotCorners, forKey: .hotCorners)
        try container.encode(defaultColumnDisplayMode, forKey: .defaultColumnDisplayMode)
        try container.encodeIfPresent(Self.clampWidth(defaultNewColumnWidth), forKey: .defaultNewColumnWidth)
        try container.encodeIfPresent(Self.clampHeight(defaultNewTileHeight), forKey: .defaultNewTileHeight)
    }

    private static func clampWidth(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(180, min(value, 2400))
    }

    private static func clampHeight(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return max(120, min(value, 2400))
    }
}

struct AppSettings: Codable, Equatable {
    static let schemaVersion = 7

    var schemaVersion: Int
    var sidebarVisible: Bool
    var inboxVisible: Bool
    var defaultCreateWorktreeForRepoSessions: Bool
    var preferredShellPath: String?
    var terminalStartupCommandTemplate: String?
    var hasSeenFirstRun: Bool
    var hasSeenNiriOnboarding: Bool
    var defaultSandboxProfile: SandboxProfile
    var defaultNetworkPolicy: NetworkPolicy
    var externalLinkRouting: ExternalLinkRouting
    var browserSplitDefaultSide: SplitSide
    var restoreBehavior: RestoreBehavior
    var cleanupOnClose: Bool
    var newSessionBehavior: NewSessionBehavior
    var defaultVibeToolID: String?
    var autoLaunchDefaultVibeToolOnCmdN: Bool
    var appMode: AppMode
    var niriCanvasEnabled: Bool
    var niri: NiriSettings
    var keybindingMode: KeybindingMode
    var modKeySetting: ModKeySetting
    var customKeybindings: [String: KeyChord]
    var workflowRailWidth: Double
    var terminalThemeID: String?

    init(
        schemaVersion: Int = AppSettings.schemaVersion,
        sidebarVisible: Bool = true,
        inboxVisible: Bool = false,
        defaultCreateWorktreeForRepoSessions: Bool = true,
        preferredShellPath: String? = nil,
        terminalStartupCommandTemplate: String? = nil,
        hasSeenFirstRun: Bool = false,
        hasSeenNiriOnboarding: Bool = false,
        defaultSandboxProfile: SandboxProfile = .fullAccess,
        defaultNetworkPolicy: NetworkPolicy = .inherited,
        externalLinkRouting: ExternalLinkRouting = .defaultBrowser,
        browserSplitDefaultSide: SplitSide = .right,
        restoreBehavior: RestoreBehavior = .relaunchAllSessions,
        cleanupOnClose: Bool = false,
        newSessionBehavior: NewSessionBehavior = .quick,
        defaultVibeToolID: String? = nil,
        autoLaunchDefaultVibeToolOnCmdN: Bool = true,
        appMode: AppMode = .hybrid,
        niriCanvasEnabled: Bool = true,
        niri: NiriSettings = NiriSettings(),
        keybindingMode: KeybindingMode = .both,
        modKeySetting: ModKeySetting = .commandOption,
        customKeybindings: [String: KeyChord] = [:],
        workflowRailWidth: Double = 300,
        terminalThemeID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sidebarVisible = sidebarVisible
        self.inboxVisible = inboxVisible
        self.defaultCreateWorktreeForRepoSessions = defaultCreateWorktreeForRepoSessions
        self.preferredShellPath = preferredShellPath
        self.terminalStartupCommandTemplate = terminalStartupCommandTemplate
        self.hasSeenFirstRun = hasSeenFirstRun
        self.hasSeenNiriOnboarding = hasSeenNiriOnboarding
        self.defaultSandboxProfile = defaultSandboxProfile
        self.defaultNetworkPolicy = defaultNetworkPolicy
        self.externalLinkRouting = externalLinkRouting
        self.browserSplitDefaultSide = browserSplitDefaultSide
        self.restoreBehavior = restoreBehavior
        self.cleanupOnClose = cleanupOnClose
        self.newSessionBehavior = newSessionBehavior
        self.defaultVibeToolID = defaultVibeToolID
        self.autoLaunchDefaultVibeToolOnCmdN = autoLaunchDefaultVibeToolOnCmdN
        self.appMode = appMode
        self.niriCanvasEnabled = niriCanvasEnabled
        self.niri = niri
        self.keybindingMode = keybindingMode
        self.modKeySetting = modKeySetting
        self.customKeybindings = customKeybindings
        self.workflowRailWidth = workflowRailWidth
        self.terminalThemeID = terminalThemeID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sidebarVisible
        case inboxVisible
        case openLinksInDefaultBrowser
        case defaultCreateWorktreeForRepoSessions
        case preferredShellPath
        case terminalStartupCommandTemplate
        case hasSeenFirstRun
        case hasSeenNiriOnboarding
        case defaultSandboxProfile
        case defaultNetworkPolicy
        case externalLinkRouting
        case browserSplitDefaultSide
        case restoreBehavior
        case cleanupOnClose
        case newSessionBehavior
        case defaultVibeToolID
        case autoLaunchDefaultVibeToolOnCmdN
        case appMode
        case niriCanvasEnabled
        case niri
        case keybindingMode
        case modKeySetting
        case customKeybindings
        case workflowRailWidth
        case terminalThemeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = AppSettings.schemaVersion
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        inboxVisible = try container.decodeIfPresent(Bool.self, forKey: .inboxVisible) ?? false
        defaultCreateWorktreeForRepoSessions = try container.decodeIfPresent(Bool.self, forKey: .defaultCreateWorktreeForRepoSessions) ?? true
        preferredShellPath = try container.decodeIfPresent(String.self, forKey: .preferredShellPath)
        terminalStartupCommandTemplate = try container.decodeIfPresent(String.self, forKey: .terminalStartupCommandTemplate)
        hasSeenFirstRun = try container.decodeIfPresent(Bool.self, forKey: .hasSeenFirstRun) ?? false
        hasSeenNiriOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenNiriOnboarding) ?? false
        defaultSandboxProfile = try container.decodeIfPresent(SandboxProfile.self, forKey: .defaultSandboxProfile) ?? .fullAccess
        defaultNetworkPolicy = try container.decodeIfPresent(NetworkPolicy.self, forKey: .defaultNetworkPolicy) ?? .inherited

        if let routing = try container.decodeIfPresent(ExternalLinkRouting.self, forKey: .externalLinkRouting) {
            externalLinkRouting = routing
        } else {
            let openLinks = try container.decodeIfPresent(Bool.self, forKey: .openLinksInDefaultBrowser) ?? true
            externalLinkRouting = openLinks ? .defaultBrowser : .embeddedBrowser
        }

        browserSplitDefaultSide = try container.decodeIfPresent(SplitSide.self, forKey: .browserSplitDefaultSide) ?? .right
        restoreBehavior = try container.decodeIfPresent(RestoreBehavior.self, forKey: .restoreBehavior) ?? .relaunchAllSessions
        cleanupOnClose = try container.decodeIfPresent(Bool.self, forKey: .cleanupOnClose) ?? false
        newSessionBehavior = try container.decodeIfPresent(NewSessionBehavior.self, forKey: .newSessionBehavior) ?? .quick
        defaultVibeToolID = try container.decodeIfPresent(String.self, forKey: .defaultVibeToolID)
        autoLaunchDefaultVibeToolOnCmdN = try container.decodeIfPresent(Bool.self, forKey: .autoLaunchDefaultVibeToolOnCmdN) ?? true
        appMode = try container.decodeIfPresent(AppMode.self, forKey: .appMode) ?? .hybrid
        niriCanvasEnabled = try container.decodeIfPresent(Bool.self, forKey: .niriCanvasEnabled) ?? true
        niri = try container.decodeIfPresent(NiriSettings.self, forKey: .niri) ?? NiriSettings()
        keybindingMode = try container.decodeIfPresent(KeybindingMode.self, forKey: .keybindingMode) ?? .both
        modKeySetting = try container.decodeIfPresent(ModKeySetting.self, forKey: .modKeySetting) ?? .commandOption
        customKeybindings = try container.decodeIfPresent([String: KeyChord].self, forKey: .customKeybindings) ?? [:]
        workflowRailWidth = try container.decodeIfPresent(Double.self, forKey: .workflowRailWidth) ?? 300
        terminalThemeID = try container.decodeIfPresent(String.self, forKey: .terminalThemeID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AppSettings.schemaVersion, forKey: .schemaVersion)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encode(inboxVisible, forKey: .inboxVisible)
        try container.encode(defaultCreateWorktreeForRepoSessions, forKey: .defaultCreateWorktreeForRepoSessions)
        try container.encodeIfPresent(preferredShellPath, forKey: .preferredShellPath)
        try container.encodeIfPresent(terminalStartupCommandTemplate, forKey: .terminalStartupCommandTemplate)
        try container.encode(hasSeenFirstRun, forKey: .hasSeenFirstRun)
        try container.encode(hasSeenNiriOnboarding, forKey: .hasSeenNiriOnboarding)
        try container.encode(defaultSandboxProfile, forKey: .defaultSandboxProfile)
        try container.encode(defaultNetworkPolicy, forKey: .defaultNetworkPolicy)
        try container.encode(externalLinkRouting, forKey: .externalLinkRouting)
        try container.encode(browserSplitDefaultSide, forKey: .browserSplitDefaultSide)
        try container.encode(restoreBehavior, forKey: .restoreBehavior)
        try container.encode(cleanupOnClose, forKey: .cleanupOnClose)
        try container.encode(newSessionBehavior, forKey: .newSessionBehavior)
        try container.encodeIfPresent(defaultVibeToolID, forKey: .defaultVibeToolID)
        try container.encode(autoLaunchDefaultVibeToolOnCmdN, forKey: .autoLaunchDefaultVibeToolOnCmdN)
        try container.encode(appMode, forKey: .appMode)
        try container.encode(niriCanvasEnabled, forKey: .niriCanvasEnabled)
        try container.encode(niri, forKey: .niri)
        try container.encode(keybindingMode, forKey: .keybindingMode)
        try container.encode(modKeySetting, forKey: .modKeySetting)
        try container.encode(customKeybindings, forKey: .customKeybindings)
        try container.encode(workflowRailWidth, forKey: .workflowRailWidth)
        try container.encodeIfPresent(terminalThemeID, forKey: .terminalThemeID)
        // Keep legacy key populated to avoid older dev builds misreading link behavior.
        try container.encode(openLinksInDefaultBrowser, forKey: .openLinksInDefaultBrowser)
    }

    var openLinksInDefaultBrowser: Bool {
        get { externalLinkRouting == .defaultBrowser }
        set { externalLinkRouting = newValue ? .defaultBrowser : .embeddedBrowser }
    }
}
