import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Browser Pane

struct NiriVSCodeTile: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let sessionID: UUID
    let itemID: UUID
    @ObservedObject var controller: VSCodeTileController

    var body: some View {
        Group {
            switch controller.state {
            case .live:
                SessionBrowserWebView(webView: controller.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .provisioning:
                niriVSCodeStatusView(
                    icon: "shippingbox",
                    title: "Preparing VS Code",
                    subtitle: "Resolving runtime requirements..."
                )
            case .downloading:
                niriVSCodeStatusView(
                    icon: "arrow.down.circle",
                    title: "Downloading VS Code",
                    subtitle: "Fetching pinned runtime artifact..."
                )
            case .extracting:
                niriVSCodeStatusView(
                    icon: "archivebox",
                    title: "Installing VS Code",
                    subtitle: "Extracting runtime files..."
                )
            case .starting:
                niriVSCodeStatusView(
                    icon: "bolt.horizontal",
                    title: "Starting VS Code",
                    subtitle: "Waiting for local runtime readiness..."
                )
            case .idle:
                niriVSCodeStatusView(
                    icon: "hourglass",
                    title: "Ready To Start",
                    subtitle: "Starting runtime..."
                )
            case .failed(let message, let logPath):
                niriVSCodeFailureView(message: message, logPath: logPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tc.surface0)
        .onTapGesture {
            sessionService.markNiriAppFocused(for: sessionID, appID: NiriAppID.vscode)
        }
        .onAppear {
            controller.ensureStarted()
        }
    }

    @ViewBuilder
    private func niriVSCodeStatusView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tc.secondaryText)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.tertiaryText)
                .frame(maxWidth: 320)

            Button("Setup Browser Debug (idx-web)") {
                _ = sessionService.setupVSCodeBrowserDebug(for: sessionID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func niriVSCodeFailureView(message: String, logPath: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("VS Code Failed To Start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.secondaryText)
                .frame(maxWidth: 360)

            if let logPath {
                Text(logPath)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    sessionService.retryNiriAppTile(sessionID: sessionID, itemID: itemID, appID: NiriAppID.vscode)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Logs") {
                    controller.openLogsInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Setup Browser Debug") {
                    _ = sessionService.setupVSCodeBrowserDebug(for: sessionID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NiriOpenCodeTile: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let sessionID: UUID
    let itemID: UUID
    @ObservedObject var controller: OpenCodeTileController

    var body: some View {
        Group {
            switch controller.state {
            case .live:
                SessionBrowserWebView(webView: controller.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .starting:
                niriOpenCodeStatusView(
                    icon: "bolt.horizontal",
                    title: "Starting OpenCode",
                    subtitle: "Launching OpenCode desktop runtime..."
                )
            case .idle:
                niriOpenCodeStatusView(
                    icon: "hourglass",
                    title: "Ready To Start",
                    subtitle: "Starting runtime..."
                )
            case .failed(let message, let logPath):
                niriOpenCodeFailureView(message: message, logPath: logPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tc.surface0)
        .onTapGesture {
            sessionService.markNiriAppFocused(for: sessionID, appID: NiriAppID.openCode)
        }
        .onAppear {
            controller.ensureStarted()
        }
    }

    @ViewBuilder
    private func niriOpenCodeStatusView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tc.secondaryText)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.tertiaryText)
                .frame(maxWidth: 320)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func niriOpenCodeFailureView(message: String, logPath: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("OpenCode Failed To Start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.secondaryText)
                .frame(maxWidth: 360)

            if let logPath {
                Text(logPath)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    sessionService.retryNiriAppTile(sessionID: sessionID, itemID: itemID, appID: NiriAppID.openCode)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Logs") {
                    controller.openLogsInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NiriT3Tile: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let sessionID: UUID
    let itemID: UUID
    @ObservedObject var controller: T3TileController

    var body: some View {
        Group {
            switch controller.state {
            case .live:
                SessionBrowserWebView(webView: controller.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preparingSource:
                niriT3StatusView(
                    icon: "shippingbox",
                    title: "Preparing T3 Code",
                    subtitle: "Fetching source and validating dependencies..."
                )
            case .building:
                niriT3StatusView(
                    icon: "hammer",
                    title: "Building T3 Code",
                    subtitle: "Compiling server artifacts for this machine..."
                )
            case .starting:
                niriT3StatusView(
                    icon: "bolt.horizontal",
                    title: "Starting T3 Code",
                    subtitle: "Waiting for local runtime readiness..."
                )
            case .idle:
                niriT3StatusView(
                    icon: "hourglass",
                    title: "Ready To Start",
                    subtitle: "Starting runtime..."
                )
            case .failed(let message, let logPath):
                niriT3FailureView(message: message, logPath: logPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tc.surface0)
        .onTapGesture {
            sessionService.markNiriAppFocused(for: sessionID, appID: NiriAppID.t3Code)
        }
        .onAppear {
            controller.ensureStarted()
        }
    }

    @ViewBuilder
    private func niriT3StatusView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tc.secondaryText)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.tertiaryText)
                .frame(maxWidth: 320)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func niriT3FailureView(message: String, logPath: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("T3 Code Failed To Start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.secondaryText)
                .frame(maxWidth: 360)

            if let logPath {
                Text(logPath)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    sessionService.retryNiriAppTile(sessionID: sessionID, itemID: itemID, appID: NiriAppID.t3Code)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Logs") {
                    controller.openLogsInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NiriExcalidrawTile: View {
    @EnvironmentObject private var sessionService: SessionService
    @Environment(\.themeColors) private var tc

    let sessionID: UUID
    let itemID: UUID
    @ObservedObject var controller: ExcalidrawTileController

    var body: some View {
        Group {
            switch controller.state {
            case .live:
                SessionBrowserWebView(webView: controller.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preparingSource:
                statusView(
                    icon: "shippingbox",
                    title: "Preparing Excalidraw",
                    subtitle: "Fetching source and validating dependencies..."
                )
            case .building:
                statusView(
                    icon: "hammer",
                    title: "Building Excalidraw",
                    subtitle: "Compiling Excalidraw static bundle..."
                )
            case .starting:
                statusView(
                    icon: "bolt.horizontal",
                    title: "Starting Excalidraw",
                    subtitle: "Waiting for local runtime readiness..."
                )
            case .idle:
                statusView(
                    icon: "hourglass",
                    title: "Ready To Start",
                    subtitle: "Starting runtime..."
                )
            case .failed(let message, let logPath):
                failureView(message: message, logPath: logPath)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tc.surface0)
        .onTapGesture {
            sessionService.markNiriAppFocused(for: sessionID, appID: NiriAppID.excalidraw)
        }
        .onAppear {
            controller.ensureStarted()
        }
    }

    @ViewBuilder
    private func statusView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tc.secondaryText)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.tertiaryText)
                .frame(maxWidth: 320)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func failureView(message: String, logPath: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.orange)

            Text("Excalidraw Failed To Start")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tc.primaryText)

            Text(message)
                .multilineTextAlignment(.center)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tc.secondaryText)
                .frame(maxWidth: 360)

            if let logPath {
                Text(logPath)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(tc.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button("Retry") {
                    sessionService.retryNiriAppTile(
                        sessionID: sessionID,
                        itemID: itemID,
                        appID: NiriAppID.excalidraw
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Open Logs") {
                    controller.openLogsInFinder()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

 struct NiriBrowserTile: View {
    @EnvironmentObject private var sessionService: SessionService

    let session: Session
    @ObservedObject var controller: SessionBrowserController

    @State private var addressBar = ""

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(
                controller: controller,
                sessionID: session.id,
                addressBar: $addressBar
            )

            SessionBrowserWebView(webView: controller.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onTapGesture {
            sessionService.markBrowserFocused(for: session.id)
        }
        .onAppear {
            if let existingURL = controller.currentURLString, !existingURL.isEmpty {
                addressBar = existingURL
                return
            }
            let fallback = "https://google.com"
            addressBar = fallback
            controller.load(urlString: fallback)
        }
        .onReceive(controller.$currentURLString) { value in
            if let value, !value.isEmpty {
                addressBar = value
            }
        }
    }
}

 struct SessionBrowserPane: View {
    @EnvironmentObject private var sessionService: SessionService

    let session: Session
    @ObservedObject var controller: SessionBrowserController

    @State private var addressBar = ""

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbar(
                controller: controller,
                sessionID: session.id,
                addressBar: $addressBar,
                showSplitControls: true,
                splitSide: session.browserState?.splitSide,
                onToggleSplitSide: {
                    let nextSide: SplitSide = (session.browserState?.splitSide == .right) ? .bottom : .right
                    sessionService.setBrowserSplitSide(for: session.id, side: nextSide)
                },
                onCloseSplit: {
                    sessionService.toggleBrowserSplit(for: session.id)
                }
            )

            SessionBrowserWebView(webView: controller.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onTapGesture {
            sessionService.markBrowserFocused(for: session.id)
        }
        .onAppear {
            addressBar = controller.currentURLString ?? session.browserState?.currentURL ?? ""
        }
        .onReceive(controller.$currentURLString) { value in
            if let value, !value.isEmpty {
                addressBar = value
            }
        }
    }
}

 struct SessionBrowserWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> BrowserWebViewContainerNSView {
        let container = BrowserWebViewContainerNSView()
        container.install(webView: webView)
        return container
    }

    func updateNSView(_ nsView: BrowserWebViewContainerNSView, context: Context) {
        _ = context
        nsView.install(webView: webView)
    }
}

 final class BrowserWebViewContainerNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(webView: WKWebView) {
        if webView.superview !== self {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
}
