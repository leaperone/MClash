#if os(macOS)
import Foundation
import ServiceManagement

@MainActor
struct LoginItemManager {
    private static let agentPlistName = "one.leaper.mclash.login.plist"

    private var legacyBackgroundAgent: SMAppService {
        SMAppService.agent(plistName: Self.agentPlistName)
    }

    var isEnabled: Bool {
        Self.isRegistered(SMAppService.mainApp.status)
            || Self.isRegistered(legacyBackgroundAgent.status)
    }

    var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
            || legacyBackgroundAgent.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !Self.isRegistered(SMAppService.mainApp.status) {
                try SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .enabled,
               Self.isRegistered(legacyBackgroundAgent.status) {
                try legacyBackgroundAgent.unregister()
            }
        } else {
            if Self.isRegistered(legacyBackgroundAgent.status) {
                try legacyBackgroundAgent.unregister()
            }
            if Self.isRegistered(SMAppService.mainApp.status) {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        guard Self.isRegistered(legacyBackgroundAgent.status) else { return }
        if !Self.isRegistered(SMAppService.mainApp.status) {
            try SMAppService.mainApp.register()
        }
        // Keep the old agent until the replacement is actually eligible to
        // launch. This avoids disabling startup while macOS awaits approval.
        if SMAppService.mainApp.status == .enabled {
            try legacyBackgroundAgent.unregister()
        }
    }

    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
#endif
