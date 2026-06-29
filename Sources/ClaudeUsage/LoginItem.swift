import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Works with an ad-hoc-signed
/// bundle, but the bundle must be signed (build-app.sh does this) and live at a
/// stable path (install to ~/Applications or /Applications).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusString: String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "notRegistered"
        case .requiresApproval: return "requiresApproval (approve in System Settings ▸ General ▸ Login Items)"
        case .notFound:         return "notFound"
        @unknown default:       return "unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LoginItem: failed to \(enabled ? "register" : "unregister"): \(error)")
            return false
        }
    }
}
