import Foundation
import SwiftUI

enum NiriAppID {
    static let t3Code = "t3-code"
    static let vscode = "vscode"
    static let excalidraw = "excalidraw"
    static let openCode = "opencode"
}

@MainActor
protocol NiriAppTileRuntimeControlling: AnyObject {
    var sessionID: UUID { get }
    func retry()
    func stop()
    @discardableResult
    func adjustZoom(by delta: CGFloat) -> Bool
}

struct NiriAppDescriptor {
    let id: String
    let displayName: String
    let icon: String
    var iconImageName: String? = nil
    let menuSubtitle: String
    let isVisibleInMenus: Bool
    let supportsWebZoomPersistence: Bool
    let startTile: @MainActor (_ sessionService: SessionService, _ sessionID: UUID) -> UUID?
    let retryTile: @MainActor (_ sessionService: SessionService, _ sessionID: UUID, _ itemID: UUID) -> Void
    let stopTile: @MainActor (_ sessionService: SessionService, _ itemID: UUID) -> Void
    let ensureController: @MainActor (_ sessionService: SessionService, _ sessionID: UUID, _ itemID: UUID) -> (any NiriAppTileRuntimeControlling)?
    let makeTileView: @MainActor (_ sessionService: SessionService, _ sessionID: UUID, _ itemID: UUID) -> AnyView
    let cleanupSessionArtifacts: (@MainActor (_ sessionService: SessionService, _ sessionID: UUID) -> Void)?
}

enum NiriAppUIVisibility {
    static func quickAddApps(from registeredApps: [NiriAppDescriptor]) -> [NiriAppDescriptor] {
        visibleApps(from: registeredApps)
    }

    static func commandPaletteApps(from registeredApps: [NiriAppDescriptor]) -> [NiriAppDescriptor] {
        visibleApps(from: registeredApps)
    }

    static func appMenuApps(from registeredApps: [NiriAppDescriptor]) -> [NiriAppDescriptor] {
        visibleApps(from: registeredApps)
    }

    private static func visibleApps(from registeredApps: [NiriAppDescriptor]) -> [NiriAppDescriptor] {
        registeredApps.filter(\.isVisibleInMenus)
    }
}

@MainActor
final class NiriAppRegistry: ObservableObject {
    static let shared = NiriAppRegistry()

    @Published private(set) var orderedDescriptors: [NiriAppDescriptor] = []

    var visibleDescriptors: [NiriAppDescriptor] {
        orderedDescriptors.filter(\.isVisibleInMenus)
    }

    init(orderedDescriptors: [NiriAppDescriptor] = []) {
        self.orderedDescriptors = orderedDescriptors
    }

    func descriptor(for id: String) -> NiriAppDescriptor? {
        orderedDescriptors.first(where: { $0.id == id })
    }

    func register(_ descriptor: NiriAppDescriptor) {
        if let existingIndex = orderedDescriptors.firstIndex(where: { $0.id == descriptor.id }) {
            orderedDescriptors[existingIndex] = descriptor
            return
        }
        orderedDescriptors.append(descriptor)
    }

    func register(contentsOf descriptors: [NiriAppDescriptor]) {
        for descriptor in descriptors {
            register(descriptor)
        }
    }

    func removeAll() {
        orderedDescriptors.removeAll()
    }
}
