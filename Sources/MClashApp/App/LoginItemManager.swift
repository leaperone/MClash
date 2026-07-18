#if os(macOS)
import Foundation
import ServiceManagement

@MainActor
struct LoginItemManager {
    private static let agentPlistName = "one.leaper.mclash.login.plist"

    private var backgroundAgent: SMAppService {
        SMAppService.agent(plistName: Self.agentPlistName)
    }

    var isEnabled: Bool {
        backgroundAgent.status == .enabled
            || SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            guard backgroundAgent.status != .enabled else { return }
            try backgroundAgent.register()
        } else {
            if backgroundAgent.status == .enabled
                || backgroundAgent.status == .requiresApproval {
                try backgroundAgent.unregister()
            }
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }

    func migrateLegacyRegistrationIfNeeded() throws {
        guard SMAppService.mainApp.status == .enabled else { return }
        if backgroundAgent.status != .enabled {
            try backgroundAgent.register()
        }
        try SMAppService.mainApp.unregister()
    }
}
#endif
