import SwiftUI

struct RenameSessionSheet: View {
    @Environment(\.themeColors) private var tc
    @EnvironmentObject private var coordinator: AppCoordinator

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search-style input
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tc.accent)

                TextField("Session name", text: $coordinator.renameDraftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit {
                        guard !coordinator.renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        coordinator.commitRenameSession()
                    }

                if !coordinator.renameDraftTitle.isEmpty {
                    Button {
                        coordinator.renameDraftTitle = ""
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
                    .onTapGesture { coordinator.cancelRenameSession() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle()
                .fill(tc.divider)
                .frame(height: 1)

            // Action row
            HStack(spacing: 8) {
                Text("Press")
                    .font(.system(size: 10))
                    .foregroundStyle(tc.tertiaryText)
                keyBadge("↵")
                Text("to rename")
                    .font(.system(size: 10))
                    .foregroundStyle(tc.tertiaryText)

                Spacer()

                Button {
                    coordinator.commitRenameSession()
                } label: {
                    Text("Rename")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            coordinator.renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? tc.mutedText : tc.accent
                        )
                }
                .buttonStyle(.plain)
                .idxHitTarget()
                .disabled(coordinator.renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(tc.sidebarBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tc.surface2.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    private func keyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(tc.tertiaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tc.surface1, in: RoundedRectangle(cornerRadius: 3))
    }
}
