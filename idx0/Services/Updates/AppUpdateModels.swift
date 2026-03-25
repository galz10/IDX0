import Foundation

enum AppUpdateStatus: String, Equatable {
    case disabled
    case idle
    case checking
    case upToDate
    case available
    case downloading
    case downloaded
    case error
}

struct AppUpdateState: Equatable {
    var currentVersion: String
    var availableVersion: String?
    var progress: Double?
    var lastCheckedAt: Date?
    var errorMessage: String?
    var enabled: Bool
    var status: AppUpdateStatus

    init(
        currentVersion: String,
        availableVersion: String? = nil,
        progress: Double? = nil,
        lastCheckedAt: Date? = nil,
        errorMessage: String? = nil,
        enabled: Bool = true,
        status: AppUpdateStatus = .idle
    ) {
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.progress = progress
        self.lastCheckedAt = lastCheckedAt
        self.errorMessage = errorMessage
        self.enabled = enabled
        self.status = status
    }
}

enum AppUpdateCheckSource: Equatable {
    case startup
    case scheduled
    case manual
    case retry
}

enum AppUpdateEvent: Equatable {
    case policyChanged(enabled: Bool)
    case checkRequested(source: AppUpdateCheckSource)
    case checkSucceeded(availableVersion: String?, checkedAt: Date)
    case checkFailed(message: String, checkedAt: Date)
    case downloadStarted
    case downloadProgress(Double)
    case downloadSucceeded
    case downloadFailed(String)
    case installStarted
    case installFailed(String)
}

enum AppUpdatePrimaryAction: Equatable {
    case check
    case download
    case install
    case retry
}

enum AppUpdateActionMapper {
    static func primaryAction(for status: AppUpdateStatus) -> AppUpdatePrimaryAction? {
        switch status {
        case .disabled, .checking, .downloading:
            return nil
        case .idle, .upToDate:
            return .check
        case .available:
            return .download
        case .downloaded:
            return .install
        case .error:
            return .retry
        }
    }

    static func primaryActionTitle(for status: AppUpdateStatus) -> String? {
        switch primaryAction(for: status) {
        case .check:
            return "Check for Updates"
        case .download:
            return "Download Update"
        case .install:
            return "Install Update"
        case .retry:
            return "Retry"
        case nil:
            return nil
        }
    }
}
