import SwiftUI

// MARK: - Shared styling (VS Code-inspired)

enum HitTargetSize {
    static let compact: CGFloat = 28
    static let dense: CGFloat = 30
}

struct SettingSectionHeader: View {
    let title: String
    @Environment(\.themeColors) private var tc

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tc.primaryText)
            .padding(.top, 18)
            .padding(.bottom, 8)
    }
}

struct SettingDivider: View {
    @Environment(\.themeColors) private var tc

    var body: some View {
        Rectangle()
            .fill(tc.surface0)
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

struct SettingRowView<Control: View>: View {
    let label: String
    let caption: String?
    @ViewBuilder let control: () -> Control
    @Environment(\.themeColors) private var tc

    init(label: String, caption: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.caption = caption
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tc.primaryText)

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(tc.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            control()
        }
        .padding(.vertical, 6)
    }
}

struct SettingToggleRow: View {
    let label: String
    let caption: String?
    @Binding var isOn: Bool
    @Environment(\.themeColors) private var tc

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThemedToggle(isOn: $isOn)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tc.primaryText)

                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(tc.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        }
    }
}

struct ThemedToggle: View {
    @Binding var isOn: Bool
    @Environment(\.themeColors) private var tc

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? tc.accent.opacity(0.35) : tc.surface0)
                    .frame(width: 28, height: 16)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? tc.accent.opacity(0.5) : tc.surface2.opacity(0.5), lineWidth: 0.5)
                    )

                Circle()
                    .fill(isOn ? tc.accent : tc.overlay0)
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ThemedPicker<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    @Environment(\.themeColors) private var tc

    @State private var isExpanded = false

    private var selectedLabel: String {
        options.first(where: { $0.1 == selection })?.0 ?? ""
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(selectedLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tc.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tc.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tc.surface0, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tc.surface2.opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let isSelected = option.1 == selection
                    Button {
                        selection = option.1
                        isExpanded = false
                    } label: {
                        HStack(spacing: 6) {
                            Text(option.0)
                                .font(.system(size: 11))
                                .foregroundStyle(isSelected ? tc.accent : tc.primaryText)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(tc.accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? tc.surface0 : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .frame(minWidth: 180)
            .background(tc.windowBackground)
        }
    }
}

private struct HitTargetModifier: ViewModifier {
    let size: CGFloat
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(minWidth: size, minHeight: size, alignment: alignment)
            .contentShape(Rectangle())
    }
}

private struct FullWidthHitRowModifier: ViewModifier {
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
    }
}

extension View {
    func idxHitTarget(size: CGFloat = HitTargetSize.compact, alignment: Alignment = .center) -> some View {
        modifier(HitTargetModifier(size: size, alignment: alignment))
    }

    func idxFullWidthHitRow(alignment: Alignment = .leading) -> some View {
        modifier(FullWidthHitRowModifier(alignment: alignment))
    }
}
