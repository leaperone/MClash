import Foundation
import MClashNetworkShared

enum ProfileTrafficTarget: Hashable, Sendable {
    case defaultProfile
    case profile(ProfileID)
    case system
}

extension MihomoRoute {
    var mclashTrafficTarget: ProfileTrafficTarget {
        guard let routingProfileID else { return .defaultProfile }
        return .profile(ProfileID(rawValue: routingProfileID.uuid))
    }

    /// Compatibility projection for code which needs the real profile backing
    /// a route. New presentation code should prefer `mclashTrafficTarget` so
    /// the virtual Default Profile stays distinct from an explicit profile.
    func mclashProfileID(defaultProfileID: ProfileID?) -> ProfileID? {
        switch mclashTrafficTarget {
        case .defaultProfile: defaultProfileID
        case let .profile(profileID): profileID
        case .system: nil
        }
    }
}

extension CaptureAction {
    var mclashTrafficTarget: ProfileTrafficTarget {
        guard case let .mihomo(route) = self else { return .system }
        return route.mclashTrafficTarget
    }

    func mclashProfileID(defaultProfileID: ProfileID?) -> ProfileID? {
        switch mclashTrafficTarget {
        case .defaultProfile: defaultProfileID
        case let .profile(profileID): profileID
        case .system: nil
        }
    }
}

extension AppRoutingActivity {
    var mclashTrafficTarget: ProfileTrafficTarget {
        if case .mihomo = configuredAction {
            return configuredAction.mclashTrafficTarget
        }
        guard case let .mihomo(route) = effectiveAction else { return .system }
        return route.mclashTrafficTarget
    }

    /// Uses the configured route so a failed or direct-fallback relay still
    /// appears under the profile the user asked App Routing to use.
    func mclashProfileID(defaultProfileID: ProfileID?) -> ProfileID? {
        switch mclashTrafficTarget {
        case .defaultProfile: defaultProfileID
        case let .profile(profileID): profileID
        case .system: nil
        }
    }
}
