#if os(macOS)
import Foundation
import SystemConfiguration

/// The production backend. Every write is staged in one SCPreferences session and committed once.
public struct SystemConfigurationProxyBackend: SystemProxyBackend {
    public init() {}

    public func enabledNetworkServices() throws -> [SystemProxyNetworkService] {
        let preferences = try makePreferences()
        let networkSet = try currentNetworkSet(preferences: preferences)
        let services = (SCNetworkSetCopyServices(networkSet) as? [SCNetworkService]) ?? []

        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                  let id = SCNetworkServiceGetServiceID(service) as String?
            else {
                return nil
            }

            let name = (SCNetworkServiceGetName(service) as String?) ?? id
            return SystemProxyNetworkService(id: id, name: name)
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        try validateUniqueServices(services)
        let preferences = try makePreferences()
        let serviceReferences = try serviceMap(preferences: preferences)

        return try services.map { service in
            guard let serviceReference = serviceReferences[service.id] else {
                throw SystemProxyError.serviceNotFound(service.id)
            }

            guard let proxyProtocol = SCNetworkServiceCopyProtocol(
                serviceReference,
                kSCNetworkProtocolTypeProxies
            ) else {
                return try SystemProxyServiceState(
                    service: service,
                    protocolExists: false,
                    configuration: nil
                )
            }

            let configuration: SystemProxyDictionary?
            if let rawConfiguration = SCNetworkProtocolGetConfiguration(proxyProtocol) {
                let propertyList = rawConfiguration as NSDictionary
                guard let dictionary = propertyList as? [String: Any] else {
                    throw SystemProxyError.invalidPropertyListValue(
                        path: "service[\(service.id)]",
                        type: String(describing: type(of: propertyList))
                    )
                }
                configuration = try SystemProxyPropertyValue.dictionary(
                    from: dictionary,
                    path: "service[\(service.id)]"
                )
            } else {
                configuration = nil
            }

            return try SystemProxyServiceState(
                service: service,
                protocolExists: true,
                configuration: configuration
            )
        }
    }

    public func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        try validateUniqueServices(states.map(\.service))
        let preferences = try makePreferences()
        guard SCPreferencesLock(preferences, true) else {
            throw SystemProxyError.lockFailed
        }
        defer { SCPreferencesUnlock(preferences) }

        SCPreferencesSynchronize(preferences)
        let serviceReferences = try serviceMap(preferences: preferences)

        for state in states {
            guard let serviceReference = serviceReferences[state.service.id] else {
                throw SystemProxyError.serviceNotFound(state.service.id)
            }

            if !state.protocolExists {
                if SCNetworkServiceCopyProtocol(serviceReference, kSCNetworkProtocolTypeProxies) != nil,
                   !SCNetworkServiceRemoveProtocolType(
                       serviceReference,
                       kSCNetworkProtocolTypeProxies
                   ) {
                    throw SystemProxyError.proxyProtocolUnavailable(state.service.id)
                }
                continue
            }

            var proxyProtocol = SCNetworkServiceCopyProtocol(
                serviceReference,
                kSCNetworkProtocolTypeProxies
            )
            if proxyProtocol == nil {
                guard SCNetworkServiceAddProtocolType(
                    serviceReference,
                    kSCNetworkProtocolTypeProxies
                ) else {
                    throw SystemProxyError.proxyProtocolUnavailable(state.service.id)
                }
                proxyProtocol = SCNetworkServiceCopyProtocol(
                    serviceReference,
                    kSCNetworkProtocolTypeProxies
                )
            }

            guard let proxyProtocol else {
                throw SystemProxyError.proxyProtocolUnavailable(state.service.id)
            }

            let rawConfiguration = state.configuration?.mapValues(\.propertyListValue) as CFDictionary?
            guard SCNetworkProtocolSetConfiguration(proxyProtocol, rawConfiguration) else {
                throw SystemProxyError.proxyProtocolUnavailable(state.service.id)
            }
        }

        guard SCPreferencesCommitChanges(preferences) else {
            throw SystemProxyError.commitFailed
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw SystemProxyError.applyFailed
        }
    }

    private func makePreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(
            nil,
            "MClash" as CFString,
            nil
        ) else {
            throw SystemProxyError.preferencesUnavailable
        }
        return preferences
    }

    private func currentNetworkSet(preferences: SCPreferences) throws -> SCNetworkSet {
        guard let networkSet = SCNetworkSetCopyCurrent(preferences) else {
            throw SystemProxyError.currentNetworkSetUnavailable
        }
        return networkSet
    }

    private func serviceMap(
        preferences: SCPreferences
    ) throws -> [String: SCNetworkService] {
        let networkSet = try currentNetworkSet(preferences: preferences)
        let services = (SCNetworkSetCopyServices(networkSet) as? [SCNetworkService]) ?? []
        return services.reduce(into: [:]) { result, service in
            if let id = SCNetworkServiceGetServiceID(service) as String? {
                result[id] = service
            }
        }
    }

    private func validateUniqueServices(
        _ services: [SystemProxyNetworkService]
    ) throws {
        var seen = Set<String>()
        for service in services where !seen.insert(service.id).inserted {
            throw SystemProxyError.duplicateService(service.id)
        }
    }
}
#endif
