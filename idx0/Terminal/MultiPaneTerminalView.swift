import AppKit
import SwiftUI

/// A single NSViewRepresentable that manages ALL pane terminals for a session
/// using pure AppKit layout. This bypasses the portal system in GhosttyTerminalView
/// which only works for single terminals (lifting NSViews into the themeFrame
/// causes lifecycle conflicts with multiple simultaneous terminals).
struct MultiPaneTerminalView: NSViewRepresentable {
    let paneTree: PaneNode
    let sessionID: UUID
    let focusedControllerID: UUID?
    let controllerProvider: (UUID) -> TerminalSessionController?
    let onFocus: (UUID) -> Void
    /// When true, the container captures a snapshot of the live terminals and
    /// displays the static image instead. The terminal grid is never resized.
    var isOverview: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MultiPaneContainerView {
        let view = MultiPaneContainerView()
        view.onPaneFocused = onFocus
        return view
    }

    func updateNSView(_ nsView: MultiPaneContainerView, context: Context) {
        nsView.onPaneFocused = onFocus
        nsView.update(
            paneTree: paneTree,
            focusedControllerID: focusedControllerID,
            controllerProvider: controllerProvider,
            isOverview: isOverview
        )
    }

    static func dismantleNSView(_ nsView: MultiPaneContainerView, coordinator: Coordinator) {
        nsView.tearDown()
    }

    final class Coordinator {}
}

// MARK: - Container View

final class MultiPaneContainerView: NSView {
    var onPaneFocused: ((UUID) -> Void)?

    private var installedControllers: [UUID: NSView] = [:]
    private var dividerViews: [NSView] = []
    private var focusBorderLayer: CALayer?

    private var currentTree: PaneNode?
    private var currentFocusedID: UUID?
    private var pendingRetryControllerIDs: Set<UUID> = []
    private var retryTimer: DispatchWorkItem?

    /// Maps controller ID back from the installed runtime view, for click detection.
    private var viewToControllerID: [ObjectIdentifier: UUID] = [:]

    nonisolated(unsafe) private var eventMonitor: Any?

    /// Overview snapshot state
    private var isOverview = false
    /// True while the snapshot is still being displayed (includes animation delay)
    /// True while overview is active or the exit animation is in progress.
    private var showingSnapshot = false
    private var snapshotRemovalItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        paneTree: PaneNode,
        focusedControllerID: UUID?,
        controllerProvider: @escaping (UUID) -> TerminalSessionController?,
        isOverview: Bool
    ) {
        let newIDs = Set(paneTree.terminalControllerIDs)
        let oldIDs = Set(installedControllers.keys)

        // Remove views for controllers no longer in the tree
        for removedID in oldIDs.subtracting(newIDs) {
            if let view = installedControllers.removeValue(forKey: removedID) {
                if let nativeView = view as? GhosttyNativeView,
                   let surface = nativeView.terminalSurface?.surface {
                    idx0_ghostty_surface_set_occlusion(surface, false)
                }
                viewToControllerID.removeValue(forKey: ObjectIdentifier(view))
                view.removeFromSuperview()
            }
        }

        // Add views for new controllers
        for controllerID in newIDs.subtracting(oldIDs) {
            guard let controller = controllerProvider(controllerID) else { continue }

            guard let runtimeView = controller.runtimeView else {
                // Surface not ready yet — schedule a retry
                scheduleRetry(controllerID: controllerID, controllerProvider: controllerProvider)
                continue
            }

            installRuntimeView(runtimeView, forController: controllerID)
        }

        // Refresh views for existing controller IDs. A controller can relaunch in place
        // (same ID, new runtimeView), so ID-set diff alone is not enough.
        for controllerID in newIDs.intersection(oldIDs) {
            guard let controller = controllerProvider(controllerID) else { continue }

            guard let runtimeView = controller.runtimeView else {
                scheduleRetry(controllerID: controllerID, controllerProvider: controllerProvider)
                continue
            }

            guard let installedView = installedControllers[controllerID] else {
                installRuntimeView(runtimeView, forController: controllerID)
                continue
            }

            let installedIsAttachedHere = installedView.superview === self
            guard installedView !== runtimeView || !installedIsAttachedHere else { continue }

            if installedView !== runtimeView {
                if let nativeView = installedView as? GhosttyNativeView,
                   let surface = nativeView.terminalSurface?.surface {
                    idx0_ghostty_surface_set_occlusion(surface, false)
                }
                viewToControllerID.removeValue(forKey: ObjectIdentifier(installedView))
                installedView.removeFromSuperview()
            }

            installRuntimeView(runtimeView, forController: controllerID)
        }

        currentTree = paneTree
        currentFocusedID = focusedControllerID

        // Handle overview transition
        let wasOverview = self.isOverview
        self.isOverview = isOverview

        if isOverview && !wasOverview {
            // Entering overview — suppress resize so the grid stays stable
            snapshotRemovalItem?.cancel()
            snapshotRemovalItem = nil
            enterOverview()
        } else if !isOverview && wasOverview {
            // Leaving overview — delay unsuppressing resize until the animation finishes
            scheduleOverviewExit()
        }

        // Install event monitor for click-to-focus
        installEventMonitorIfNeeded()

        // Trigger layout
        needsLayout = true

        // Sync keyboard focus to the focused pane's controller
        if !isOverview && !showingSnapshot, let focusedControllerID,
           let controller = controllerProvider(focusedControllerID) {
            DispatchQueue.main.async {
                controller.syncFocusIfNeeded()
            }
        }
    }

    private func enterOverview() {
        showingSnapshot = true

        // Suppress resize so the terminal grid doesn't reflow during overview.
        // The live terminal stays visible — it just scales with its container.
        for (_, view) in installedControllers {
            if let nativeView = view as? GhosttyNativeView {
                nativeView.suppressResize = true
            }
        }
    }

    private func scheduleOverviewExit() {
        // Wait for the overview-close animation to finish before unsuppressing
        // resize. The animation is 0.35s spring — wait a bit longer to be safe.
        snapshotRemovalItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.exitOverview()
            self?.needsLayout = true
        }
        snapshotRemovalItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    private func exitOverview() {
        showingSnapshot = false

        // Unsuppress resize and kick a resize to the current (final) bounds
        for (_, view) in installedControllers {
            if let nativeView = view as? GhosttyNativeView {
                nativeView.suppressResize = false
                nativeView.terminalSurface?.resizeToCurrentViewBounds()
            }
        }
    }

    private func installRuntimeView(_ runtimeView: NSView, forController controllerID: UUID) {
        runtimeView.removeFromSuperview()
        runtimeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(runtimeView)
        installedControllers[controllerID] = runtimeView
        viewToControllerID[ObjectIdentifier(runtimeView)] = controllerID

        // Mark visible and kick render
        if let nativeView = runtimeView as? GhosttyNativeView,
           let surface = nativeView.terminalSurface?.surface {
            idx0_ghostty_surface_set_occlusion(surface, true)
            idx0_ghostty_surface_refresh(surface)
            GhosttyAppHost.shared.scheduleTick()
        }
    }

    private func scheduleRetry(controllerID: UUID, controllerProvider: @escaping (UUID) -> TerminalSessionController?) {
        pendingRetryControllerIDs.insert(controllerID)
        retryTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pending = self.pendingRetryControllerIDs
            self.pendingRetryControllerIDs.removeAll()

            for id in pending {
                guard let controller = controllerProvider(id) else { continue }
                guard let runtimeView = controller.runtimeView else {
                    // Still not ready — retry again
                    self.scheduleRetry(controllerID: id, controllerProvider: controllerProvider)
                    continue
                }

                if let installedView = self.installedControllers[id] {
                    let installedIsAttachedHere = installedView.superview === self
                    if installedView === runtimeView && installedIsAttachedHere {
                        if id == self.currentFocusedID {
                            controller.syncFocusIfNeeded()
                        }
                        continue
                    }

                    if installedView !== runtimeView {
                        if let nativeView = installedView as? GhosttyNativeView,
                           let surface = nativeView.terminalSurface?.surface {
                            idx0_ghostty_surface_set_occlusion(surface, false)
                        }
                        self.viewToControllerID.removeValue(forKey: ObjectIdentifier(installedView))
                        installedView.removeFromSuperview()
                    } else {
                        // Same runtime view object but detached from us; clear stale mapping
                        // before re-installing it.
                        self.viewToControllerID.removeValue(forKey: ObjectIdentifier(installedView))
                    }
                }

                self.installRuntimeView(runtimeView, forController: id)
                self.needsLayout = true
                if id == self.currentFocusedID {
                    controller.syncFocusIfNeeded()
                }
            }
        }
        retryTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let window = self.window, event.window === window else { return }

        let locationInSelf = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locationInSelf) else { return }

        // Find which terminal view was hit
        for (controllerID, view) in installedControllers {
            let locationInView = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(locationInView) {
                onPaneFocused?(controllerID)
                break
            }
        }
    }

    override func layout() {
        super.layout()

        // Remove old dividers
        for divider in dividerViews {
            divider.removeFromSuperview()
        }
        dividerViews.removeAll()

        guard let tree = currentTree else { return }

        // During overview (or animation-out), don't resize the terminal grid.
        // The live terminal stays visible and scales with its container.
        if showingSnapshot {
            return
        }

        layoutNode(tree, in: bounds)
        updateFocusBorder()
    }

    private func layoutNode(_ node: PaneNode, in rect: NSRect) {
        switch node {
        case .terminal(_, let controllerID):
            if let view = installedControllers[controllerID] {
                view.frame = rect
                if let nativeView = view as? GhosttyNativeView {
                    nativeView.terminalSurface?.resizeToCurrentViewBounds()
                }
            }

        case .split(_, let direction, let first, let second, let fraction):
            let dividerThickness: CGFloat = 1

            if direction == .vertical {
                let leftWidth = max(60, (rect.width - dividerThickness) * fraction)
                let rightWidth = max(60, rect.width - leftWidth - dividerThickness)

                let leftRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: leftWidth, height: rect.height)
                let dividerRect = NSRect(x: rect.origin.x + leftWidth, y: rect.origin.y, width: dividerThickness, height: rect.height)
                let rightRect = NSRect(x: rect.origin.x + leftWidth + dividerThickness, y: rect.origin.y, width: rightWidth, height: rect.height)

                layoutNode(first, in: leftRect)
                addDivider(frame: dividerRect)
                layoutNode(second, in: rightRect)

            } else {
                // Horizontal = stacked. AppKit y is bottom-up.
                let bottomHeight = max(60, (rect.height - dividerThickness) * (1 - fraction))
                let topHeight = max(60, rect.height - bottomHeight - dividerThickness)

                let topRect = NSRect(x: rect.origin.x, y: rect.origin.y + bottomHeight + dividerThickness, width: rect.width, height: topHeight)
                let dividerRect = NSRect(x: rect.origin.x, y: rect.origin.y + bottomHeight, width: rect.width, height: dividerThickness)
                let bottomRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: bottomHeight)

                layoutNode(first, in: topRect)
                addDivider(frame: dividerRect)
                layoutNode(second, in: bottomRect)
            }
        }
    }

    private func addDivider(frame: NSRect) {
        let divider = NSView(frame: frame)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(divider)
        dividerViews.append(divider)
    }

    private func updateFocusBorder() {
        focusBorderLayer?.removeFromSuperlayer()
        focusBorderLayer = nil

        // Skip internal focus border when there's only one pane — the niri tile overlay handles it
        guard installedControllers.count > 1 else { return }

        guard let focusedID = currentFocusedID,
              let view = installedControllers[focusedID] else { return }

        let border = CALayer()
        border.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        border.borderWidth = 2
        border.cornerRadius = 3
        border.frame = view.frame.insetBy(dx: 1, dy: 1)
        border.zPosition = 1000
        layer?.addSublayer(border)
        focusBorderLayer = border
    }

    func tearDown() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        retryTimer?.cancel()
        snapshotRemovalItem?.cancel()
        snapshotRemovalItem = nil
        showingSnapshot = false

        for (_, view) in installedControllers {
            if let nativeView = view as? GhosttyNativeView,
               let surface = nativeView.terminalSurface?.surface {
                idx0_ghostty_surface_set_occlusion(surface, false)
            }
        }
        installedControllers.removeAll()
        viewToControllerID.removeAll()

        for divider in dividerViews {
            divider.removeFromSuperview()
        }
        dividerViews.removeAll()
        focusBorderLayer?.removeFromSuperlayer()
        focusBorderLayer = nil
    }

    deinit {
        let monitor = eventMonitor
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
