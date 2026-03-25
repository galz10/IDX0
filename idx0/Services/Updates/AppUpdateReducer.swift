import Foundation

enum AppUpdateReducer {
    static func reduce(state: AppUpdateState, event: AppUpdateEvent) -> AppUpdateState {
        var next = state

        switch event {
        case .policyChanged(let enabled):
            next.enabled = enabled
            next.progress = nil
            if !enabled {
                next.status = .disabled
                next.errorMessage = nil
            } else if next.status == .disabled {
                next.status = .idle
                next.errorMessage = nil
            }

        case .checkRequested:
            guard next.enabled else { return next }
            if next.status == .checking || next.status == .downloading {
                return next
            }
            next.status = .checking
            next.errorMessage = nil
            next.progress = nil

        case .checkSucceeded(let availableVersion, let checkedAt):
            guard next.enabled else { return next }
            next.lastCheckedAt = checkedAt
            next.errorMessage = nil
            next.progress = nil
            next.availableVersion = availableVersion
            next.status = availableVersion == nil ? .upToDate : .available

        case .checkFailed(let message, let checkedAt):
            guard next.enabled else { return next }
            next.lastCheckedAt = checkedAt
            next.errorMessage = message
            next.progress = nil
            next.status = .error

        case .downloadStarted:
            guard next.enabled else { return next }
            next.status = .downloading
            next.progress = 0
            next.errorMessage = nil

        case .downloadProgress(let value):
            guard next.enabled else { return next }
            next.status = .downloading
            next.progress = min(max(value, 0), 1)

        case .downloadSucceeded:
            guard next.enabled else { return next }
            next.status = .downloaded
            next.progress = 1
            next.errorMessage = nil

        case .downloadFailed(let message):
            guard next.enabled else { return next }
            next.status = .error
            next.progress = nil
            next.errorMessage = message

        case .installStarted:
            guard next.enabled else { return next }
            next.errorMessage = nil

        case .installFailed(let message):
            guard next.enabled else { return next }
            next.status = .error
            next.errorMessage = message
        }

        return next
    }
}
