import AppKit
import XCTest
@testable import idx0

extension SessionServiceTests {
    func testBrowserConsentPromptAppearsAndQueuesOnFirstBrowserOpen() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        service.saveSettings { settings in
            settings.browserControlConsent = .undecided
            settings.niriCanvasEnabled = false
        }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser Consent Queue")).session
        service.requestToggleBrowserSplit(for: session.id)

        XCTAssertEqual(service.queuedBrowserOpenIntents.count, 1)
        XCTAssertNotNil(service.pendingBrowserControlConsentPrompt)
        XCTAssertFalse(service.sessions.first(where: { $0.id == session.id })?.browserState?.isVisible ?? false)
    }

    func testBrowserConsentDeclineReplaysQueuedIntentAndSuppressesFuturePrompt() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        service.saveSettings { settings in
            settings.browserControlConsent = .undecided
            settings.niriCanvasEnabled = false
        }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser Consent Decline")).session
        service.requestToggleBrowserSplit(for: session.id)
        service.performBrowserControlConsentSecondaryAction()

        XCTAssertEqual(service.settings.browserControlConsent, .declined)
        XCTAssertTrue(service.sessions.first(where: { $0.id == session.id })?.browserState?.isVisible ?? false)
        XCTAssertNil(service.pendingBrowserControlConsentPrompt)
        XCTAssertTrue(service.queuedBrowserOpenIntents.isEmpty)

        service.requestToggleBrowserSplit(for: session.id)
        XCTAssertNil(service.pendingBrowserControlConsentPrompt)
        XCTAssertFalse(service.sessions.first(where: { $0.id == session.id })?.browserState?.isVisible ?? true)
    }

    func testBrowserConsentEnableSuccessStoresEnabledAndReplaysQueuedIntent() async throws {
        let setupService = StubBrowserControlSetupService(results: [.success])
        let fixture = try Fixture(browserControlSetupService: setupService)
        let service = fixture.service
        service.saveSettings { settings in
            settings.browserControlConsent = .undecided
            settings.niriCanvasEnabled = false
        }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser Consent Enable")).session
        service.requestToggleBrowserSplit(for: session.id)
        service.performBrowserControlConsentPrimaryAction()

        await waitForCondition {
            service.pendingBrowserControlConsentPrompt == nil &&
                service.settings.browserControlConsent == .enabled &&
                (service.sessions.first(where: { $0.id == session.id })?.browserState?.isVisible ?? false)
        }

        let invocations = await setupService.recordedInvocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.force, false)
    }

    func testBrowserConsentEnableFailureKeepsUndecidedShowsErrorAndStillReplaysIntent() async throws {
        let setupService = StubBrowserControlSetupService(results: [.failure("setup failed")])
        let fixture = try Fixture(browserControlSetupService: setupService)
        let service = fixture.service
        service.saveSettings { settings in
            settings.browserControlConsent = .undecided
            settings.niriCanvasEnabled = false
        }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser Consent Failure")).session
        service.requestToggleBrowserSplit(for: session.id)
        service.performBrowserControlConsentPrimaryAction()

        await waitForCondition {
            service.pendingBrowserControlConsentPrompt?.isInstalling == false &&
                service.pendingBrowserControlConsentPrompt?.setupErrorMessage != nil
        }

        XCTAssertEqual(service.settings.browserControlConsent, .undecided)
        XCTAssertTrue(service.sessions.first(where: { $0.id == session.id })?.browserState?.isVisible ?? false)
        XCTAssertTrue(service.queuedBrowserOpenIntents.isEmpty)
    }

    func testBrowserConsentGateCoversNiriBrowserTileAndClipboardOpen() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        service.saveSettings { settings in
            settings.browserControlConsent = .undecided
            settings.niriCanvasEnabled = true
        }

        let session = try await service.createSession(from: SessionCreationRequest(title: "Browser Action Coverage")).session
        service.ensureNiriLayoutState(for: session.id)

        let niriResult = service.requestAddNiriBrowserTile(in: session.id)
        XCTAssertNil(niriResult)
        XCTAssertEqual(service.queuedBrowserOpenIntents.count, 1)
        XCTAssertNotNil(service.pendingBrowserControlConsentPrompt)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com", forType: .string)
        let openedClipboard = service.requestOpenClipboardURLInSplit(for: session.id)
        XCTAssertTrue(openedClipboard)
        XCTAssertEqual(service.queuedBrowserOpenIntents.count, 2)
    }

    private func waitForCondition(
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor StubBrowserControlSetupService: BrowserControlSetupServicing {
    enum Result {
        case success
        case failure(String)
    }

    struct Invocation: Equatable {
        let force: Bool
    }

    private var results: [Result]
    private var invocations: [Invocation] = []

    init(results: [Result]) {
        self.results = results
    }

    func provision(force: Bool, preferredBrowserAppURL: URL?) async throws -> BrowserControlSetupResult {
        invocations.append(Invocation(force: force))
        let next = results.isEmpty ? .success : results.removeFirst()
        switch next {
        case .success:
            return BrowserControlSetupResult(
                serverName: BrowserControlSetupService.mcpServerName,
                wrapperCommand: ["/tmp/idx0-browser-wrapper"],
                wrapperScriptPath: "/tmp/idx0-browser-wrapper",
                chromiumProfilePath: "/tmp/idx0-browser-profile",
                browserExecutablePath: nil,
                configuredToolIDs: [],
                skippedToolIDs: []
            )
        case .failure(let message):
            throw NSError(domain: "BrowserControlSetupTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}
