import AppKit
import Foundation

@MainActor
final class TerminalSessionController: ObservableObject {
    enum TerminalRuntimeState: Equatable {
        case idle
        case launching
        case running
        case terminated(exitCode: Int32?)
        case failedToLaunch(String)
    }

    let sessionID: UUID
    let launchDirectory: String
    let shellPath: String
    let launchBlockedReason: String?

    @Published private(set) var runtimeState: TerminalRuntimeState = .idle

    var onTitleChanged: ((String) -> Void)?
    var onCwdChanged: ((String) -> Void)?
    var onRuntimeStateChanged: ((TerminalRuntimeState) -> Void)?

    private(set) var terminalSurface: GhosttyTerminalSurface?
    private(set) var runtimeView: NSView?

    private let host: GhosttyAppHost
    private var needsFocus = false
    private var launchQueued = false
    private var pendingInputs: [PendingInputAction] = []

    private enum PendingInputAction {
        case text(String)
        case returnKey
    }

    init(
        sessionID: UUID,
        launchDirectory: String,
        shellPath: String,
        launchBlockedReason: String? = nil,
        host: GhosttyAppHost = .shared
    ) {
        self.sessionID = sessionID
        self.launchDirectory = launchDirectory
        self.shellPath = shellPath
        self.launchBlockedReason = launchBlockedReason
        self.host = host
    }

    func ensureLaunched() {
        switch runtimeState {
        case .idle, .failedToLaunch:
            break
        default:
            if runtimeView == nil {
                runtimeView = terminalSurface?.view
            }
            return
        }

        setRuntimeState(.launching)

        if let launchBlockedReason {
            setRuntimeState(.failedToLaunch(launchBlockedReason))
            runtimeView = FallbackTerminalView(message: launchBlockedReason)
            return
        }

        guard host.availability.isAvailable else {
            let reason = host.availability.unavailableReason
            setRuntimeState(.failedToLaunch(reason))
            runtimeView = FallbackTerminalView(message: reason)
            return
        }

        guard let surface = host.makeSurface(
            sessionID: sessionID,
            workingDirectory: launchDirectory,
            shellPath: shellPath
        ) else {
            setRuntimeState(.failedToLaunch("Could not create Ghostty surface"))
            runtimeView = FallbackTerminalView(message: "Failed to create Ghostty surface")
            return
        }

        terminalSurface = surface
        runtimeView = surface.view
        setRuntimeState(.running)
        flushPendingSendsIfNeeded()
        needsFocus = true
    }

    func requestLaunchIfNeeded() {
        switch runtimeState {
        case .idle, .failedToLaunch:
            break
        default:
            if runtimeView == nil {
                runtimeView = terminalSurface?.view
            }
            return
        }

        guard !launchQueued else { return }
        launchQueued = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.launchQueued = false
            self.ensureLaunched()
        }
    }

    func focus() {
        needsFocus = true
        syncFocusIfNeeded()
    }

    func syncFocusIfNeeded() {
        guard needsFocus else { return }
        guard let surface = terminalSurface else { return }
        needsFocus = false
        surface.focus()
    }

    func clearSelection() {
        // API removed in current Ghostty SDK; selection clears on focus/input.
    }

    func refresh() {
        terminalSurface?.refresh()
    }

    func send(text: String) {
        if case .running = runtimeState,
           let surface = terminalSurface {
            surface.send(text: text)
            return
        }

        pendingInputs.append(.text(text))
        requestLaunchIfNeeded()
    }

    func sendReturnKey() {
        if case .running = runtimeState,
           let surface = terminalSurface {
            surface.sendReturnKey()
            return
        }

        pendingInputs.append(.returnKey)
        requestLaunchIfNeeded()
    }

    func terminate(freeSynchronously: Bool = false) {
        terminalSurface?.destroy(freeSynchronously: freeSynchronously)
        terminalSurface = nil
        setRuntimeState(.terminated(exitCode: nil))
    }

    func markProcessExited(exitCode: Int32? = nil) {
        setRuntimeState(.terminated(exitCode: exitCode))
    }

    private func setRuntimeState(_ state: TerminalRuntimeState) {
        runtimeState = state
        onRuntimeStateChanged?(state)
    }

    private func flushPendingSendsIfNeeded() {
        guard case .running = runtimeState,
              let surface = terminalSurface,
              !pendingInputs.isEmpty else { return }

        let queued = pendingInputs
        pendingInputs.removeAll(keepingCapacity: true)
        for action in queued {
            switch action {
            case .text(let text):
                surface.send(text: text)
            case .returnKey:
                surface.sendReturnKey()
            }
        }
    }
}

private extension GhosttyAppHost.Availability {
    var unavailableReason: String {
        switch self {
        case .available:
            return ""
        case .unavailable(let reason):
            return reason
        }
    }
}

final class FallbackTerminalView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let label = NSTextField(labelWithString: "libghostty unavailable")
        label.font = .systemFont(ofSize: 17, weight: .semibold)

        let detail = NSTextField(labelWithString: message)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3

        let stack = NSStackView(views: [label, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
