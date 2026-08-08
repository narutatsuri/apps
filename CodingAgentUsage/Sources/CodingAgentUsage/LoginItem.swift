import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService. Requires a signed bundle in a stable location —
/// build.sh installs to /Applications and ad-hoc signs, which satisfies both.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }

    /// macOS lets the user override this in System Settings; surface that rather than
    /// silently showing a toggle that snaps back.
    static var isBlockedByUser: Bool { SMAppService.mainApp.status == .requiresApproval }
}
