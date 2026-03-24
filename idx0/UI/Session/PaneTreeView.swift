import SwiftUI

struct PaneTreeView: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let node: PaneNode
    let sessionID: UUID
    let focusedControllerID: UUID?
    let onFocus: (UUID) -> Void

    var body: some View {
        switch node {
        case .terminal(_, let controllerID):
            if let controller = sessionService.paneController(for: controllerID) {
                let isFocused = focusedControllerID == controllerID
                GhosttyTerminalView(controller: controller)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(tc.accent.opacity(isFocused ? 0.6 : 0), lineWidth: 2)
                            .shadow(color: tc.accent.opacity(isFocused ? 0.15 : 0), radius: isFocused ? 6 : 0)
                            .padding(1)
                            .animation(.easeOut(duration: 0.15), value: isFocused)
                    }
                    .onTapGesture {
                        onFocus(controllerID)
                    }
            }

        case .split(let id, let direction, let first, let second, let fraction):
            AnimatedPaneSplit(
                splitID: id,
                direction: direction,
                first: first,
                second: second,
                targetFraction: fraction,
                sessionID: sessionID,
                focusedControllerID: focusedControllerID,
                onFocus: onFocus
            )
            .environmentObject(sessionService)
        }
    }
}

/// Animates the split fraction from 0→target when a pane is first created,
/// giving the visual impression of the pane "opening up."
private struct AnimatedPaneSplit: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let splitID: UUID
    let direction: PaneSplitDirection
    let first: PaneNode
    let second: PaneNode
    let targetFraction: Double
    let sessionID: UUID
    let focusedControllerID: UUID?
    let onFocus: (UUID) -> Void

    @State private var animatedFraction: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let fraction = animatedFraction
            if direction == .vertical {
                let leftWidth = max(60, proxy.size.width * fraction)
                let rightWidth = max(60, proxy.size.width - leftWidth - 1)
                HStack(spacing: 0) {
                    PaneTreeView(node: first, sessionID: sessionID, focusedControllerID: focusedControllerID, onFocus: onFocus)
                        .frame(width: leftWidth)

                    Rectangle()
                        .fill(tc.divider)
                        .frame(width: 1)

                    PaneTreeView(node: second, sessionID: sessionID, focusedControllerID: focusedControllerID, onFocus: onFocus)
                        .frame(width: rightWidth)
                }
            } else {
                let topHeight = max(60, proxy.size.height * fraction)
                let bottomHeight = max(60, proxy.size.height - topHeight - 1)
                VStack(spacing: 0) {
                    PaneTreeView(node: first, sessionID: sessionID, focusedControllerID: focusedControllerID, onFocus: onFocus)
                        .frame(height: topHeight)

                    Rectangle()
                        .fill(tc.divider)
                        .frame(height: 1)

                    PaneTreeView(node: second, sessionID: sessionID, focusedControllerID: focusedControllerID, onFocus: onFocus)
                        .frame(height: bottomHeight)
                }
            }
        }
        .onAppear {
            if animatedFraction == 0 {
                withAnimation(.easeOut(duration: 0.2)) {
                    animatedFraction = targetFraction
                }
            }
        }
        .onChange(of: targetFraction) { _, newFraction in
            withAnimation(.easeOut(duration: 0.15)) {
                animatedFraction = newFraction
            }
        }
    }
}
