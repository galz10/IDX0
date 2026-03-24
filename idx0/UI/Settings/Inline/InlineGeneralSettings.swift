import SwiftUI

// MARK: - General

struct InlineGeneralSettings: View {
    @ObservedObject var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingSectionHeader(title: "Mode")

            SettingRowView(label: "App Mode", caption: "Terminal: clean shell. Hybrid: agent features when relevant. Vibe Studio: all features enabled.") {
                ThemedPicker(
                    options: AppMode.allCases.map { ($0.displayLabel, $0) },
                    selection: enumBinding(\.appMode)
                )
            }

            SettingToggleRow(
                label: "Niri Canvas Mode",
                caption: "Replace the default split-pane layout with a scrollable canvas of terminal and app tiles.",
                isOn: binding(\.niriCanvasEnabled)
            )

            if sessionService.settings.niriCanvasEnabled {
                SettingDivider()
                SettingSectionHeader(title: "Niri Canvas")

                SettingRowView(label: "Default Column Display", caption: "How new columns are displayed on the canvas.") {
                    ThemedPicker(
                        options: [("Normal", NiriColumnDisplayMode.normal), ("Tabbed", NiriColumnDisplayMode.tabbed)],
                        selection: niriDefaultColumnDisplayBinding()
                    )
                }

                SettingRowView(
                    label: "Default New Column Width",
                    caption: "Optional width for newly created columns only (180 to 2400). Leave empty for automatic sizing."
                ) {
                    TextField(
                        "Auto",
                        text: niriOptionalDimensionBinding(
                            get: { $0.defaultNewColumnWidth },
                            set: { settings, value in settings.defaultNewColumnWidth = value },
                            lowerBound: 180,
                            upperBound: 2400
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 180, alignment: .leading)
                }

                SettingRowView(
                    label: "Default New Tile Height",
                    caption: "Optional height for newly created tiles only (120 to 2400). Leave empty for automatic sizing."
                ) {
                    TextField(
                        "Auto",
                        text: niriOptionalDimensionBinding(
                            get: { $0.defaultNewTileHeight },
                            set: { settings, value in settings.defaultNewTileHeight = value },
                            lowerBound: 120,
                            upperBound: 2400
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 180, alignment: .leading)
                }

                SettingToggleRow(
                    label: "Snap Gestures",
                    caption: "High-velocity trackpad gestures will snap to the nearest workspace or column target.",
                    isOn: niriSnapEnabledBinding()
                )

                SettingToggleRow(
                    label: "Resize Camera Visualizer",
                    caption: "Show a live preview highlighting impacted tiles during overview resize.",
                    isOn: niriResizeCameraVisualizerBinding()
                )
            }

            SettingDivider()
            SettingSectionHeader(title: "Layout")

            SettingToggleRow(label: "Show Sidebar", caption: nil, isOn: binding(\.sidebarVisible))
            SettingToggleRow(label: "Show Workflow Rail", caption: nil, isOn: binding(\.inboxVisible))

            SettingRowView(label: "External Links", caption: "Where to open links clicked inside terminal output.") {
                ThemedPicker(
                    options: ExternalLinkRouting.allCases.map { ($0.displayLabel, $0) },
                    selection: enumBinding(\.externalLinkRouting)
                )
            }

            SettingRowView(label: "Browser Split Side", caption: "Which side of the terminal the embedded browser opens on.") {
                ThemedPicker(
                    options: SplitSide.allCases.map { ($0 == .right ? "Right" : "Bottom", $0) },
                    selection: enumBinding(\.browserSplitDefaultSide)
                )
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { sessionService.settings[keyPath: keyPath] },
            set: { value in sessionService.saveSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func enumBinding<Value: Hashable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { sessionService.settings[keyPath: keyPath] },
            set: { value in sessionService.saveSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func niriDefaultColumnDisplayBinding() -> Binding<NiriColumnDisplayMode> {
        Binding(
            get: { sessionService.settings.niri.defaultColumnDisplayMode },
            set: { value in sessionService.saveSettings { $0.niri.defaultColumnDisplayMode = value } }
        )
    }

    private func niriSnapEnabledBinding() -> Binding<Bool> {
        Binding(
            get: { sessionService.settings.niri.snapEnabled },
            set: { value in sessionService.saveSettings { $0.niri.snapEnabled = value } }
        )
    }

    private func niriResizeCameraVisualizerBinding() -> Binding<Bool> {
        Binding(
            get: { sessionService.settings.niri.resizeCameraVisualizerEnabled },
            set: { value in sessionService.saveSettings { $0.niri.resizeCameraVisualizerEnabled = value } }
        )
    }

    private func niriOptionalDimensionBinding(
        get: @escaping (NiriSettings) -> Double?,
        set: @escaping (inout NiriSettings, Double?) -> Void,
        lowerBound: Double,
        upperBound: Double
    ) -> Binding<String> {
        Binding(
            get: {
                guard let value = get(sessionService.settings.niri) else { return "" }
                return String(Int(value.rounded()))
            },
            set: { rawValue in
                sessionService.saveSettings { settings in
                    let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else {
                        set(&settings.niri, nil)
                        return
                    }
                    guard let parsed = Double(cleaned) else { return }
                    set(&settings.niri, max(lowerBound, min(parsed, upperBound)))
                }
            }
        )
    }
}
