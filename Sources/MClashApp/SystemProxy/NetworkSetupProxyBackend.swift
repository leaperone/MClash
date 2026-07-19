#if os(macOS)
import Foundation

/// Uses Apple's `networksetup` utility, matching the macOS system-proxy path used by Clash Verge.
/// Arguments are passed directly to Process; no shell, sudo, or AppleScript is involved.
struct NetworkSetupProxyBackend: SystemProxyBackend {
    private let reader: any SystemProxyBackend
    private let runner: any NetworkSetupCommandRunning
    private let serviceNameCache: NetworkSetupServiceNameCache

    init(
        reader: any SystemProxyBackend = SystemConfigurationProxyBackend(),
        runner: any NetworkSetupCommandRunning = ProcessNetworkSetupRunner(),
        serviceCatalogCacheLifetime: Duration = .seconds(30),
        serviceCatalogNow: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        }
    ) {
        self.reader = reader
        self.runner = runner
        serviceNameCache = NetworkSetupServiceNameCache(
            lifetime: serviceCatalogCacheLifetime,
            now: serviceCatalogNow
        )
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] {
        let services = try reader.enabledNetworkServices()
        let supportedNames = try networkServiceNames(
            covering: Set(services.map(\.name))
        )
        return services.filter { supportedNames.contains($0.name) }
    }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        try reader.proxyStates(for: services)
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        let currentServices = try reader.enabledNetworkServices()
        var supportedNames = try networkServiceNames(
            covering: Set(currentServices.map(\.name))
        )
        let servicesByID = Dictionary(uniqueKeysWithValues: currentServices.map { ($0.id, $0) })
        if states.contains(where: { state in
            guard let currentService = servicesByID[state.service.id] else { return false }
            return !supportedNames.contains(currentService.name)
        }) {
            serviceNameCache.invalidate()
            supportedNames = try networkServiceNames(
                covering: Set(currentServices.map(\.name))
            )
        }
        if let unavailableState = states.first(where: { state in
            guard let currentService = servicesByID[state.service.id] else { return true }
            return !supportedNames.contains(currentService.name)
        }) {
            throw SystemProxyError.serviceNotFound(unavailableState.service.id)
        }
        let writer = NetworkSetupWriter(runner: runner)
        do {
            for state in states {
                guard let currentService = servicesByID[state.service.id] else {
                    throw SystemProxyError.serviceNotFound(state.service.id)
                }
                try apply(
                    SystemProxyServiceState(
                        service: currentService,
                        protocolExists: state.protocolExists,
                        configuration: state.configuration
                    ),
                    writer: writer
                )
            }
        } catch {
            // A service can be enabled, disabled, renamed, or replaced while the
            // app is running. Make the next guard pass reload the catalog instead
            // of preserving a stale success or failure until relaunch.
            serviceNameCache.invalidate()
            throw error
        }
    }

    private func apply(_ state: SystemProxyServiceState, writer: NetworkSetupWriter) throws {
        let service = state.service.name
        let configuration = state.configuration ?? [:]

        try setAutomaticProxy(configuration, service: service, writer: writer)
        try setProxy(
            configuration,
            service: service,
            hostKey: SystemProxyKeys.httpHost,
            portKey: SystemProxyKeys.httpPort,
            enableKey: SystemProxyKeys.httpEnable,
            setCommand: "-setwebproxy",
            stateCommand: "-setwebproxystate",
            writer: writer
        )
        try setProxy(
            configuration,
            service: service,
            hostKey: SystemProxyKeys.httpsHost,
            portKey: SystemProxyKeys.httpsPort,
            enableKey: SystemProxyKeys.httpsEnable,
            setCommand: "-setsecurewebproxy",
            stateCommand: "-setsecurewebproxystate",
            writer: writer
        )
        try setProxy(
            configuration,
            service: service,
            hostKey: SystemProxyKeys.socksHost,
            portKey: SystemProxyKeys.socksPort,
            enableKey: SystemProxyKeys.socksEnable,
            setCommand: "-setsocksfirewallproxy",
            stateCommand: "-setsocksfirewallproxystate",
            writer: writer
        )
        try setBypassDomains(configuration, service: service, writer: writer)
    }

    private func setAutomaticProxy(
        _ configuration: SystemProxyDictionary,
        service: String,
        writer: NetworkSetupWriter
    ) throws {
        let pacURL = stringValue(configuration[SystemProxyKeys.pacURL])
        if let pacURL {
            try writer.run(["-setautoproxyurl", service, pacURL])
        }
        try writer.run([
            "-setautoproxystate",
            service,
            pacURL == nil ? "off" : enabledValue(configuration[SystemProxyKeys.pacEnable])
        ])
        try writer.run([
            "-setproxyautodiscovery",
            service,
            enabledValue(configuration[SystemProxyKeys.autoDiscoveryEnable])
        ])
    }

    private func setProxy(
        _ configuration: SystemProxyDictionary,
        service: String,
        hostKey: String,
        portKey: String,
        enableKey: String,
        setCommand: String,
        stateCommand: String,
        writer: NetworkSetupWriter
    ) throws {
        if let host = stringValue(configuration[hostKey]),
           let port = integerValue(configuration[portKey]),
           (1...65_535).contains(port) {
            try writer.run([setCommand, service, host, String(port)])
        }
        try writer.run([stateCommand, service, enabledValue(configuration[enableKey])])
    }

    private func setBypassDomains(
        _ configuration: SystemProxyDictionary,
        service: String,
        writer: NetworkSetupWriter
    ) throws {
        let domains = stringArrayValue(configuration[SystemProxyKeys.exceptionsList])
        try writer.run(
            ["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains)
        )
    }

    private func networkServiceNames(
        covering observedNames: Set<String>
    ) throws -> Set<String> {
        try serviceNameCache.supportedNames(covering: observedNames) {
            let output = try runner.run(["-listallnetworkservices"])
            return Set(
                output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                    let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty,
                          !name.hasPrefix("An asterisk"),
                          !name.hasPrefix("*") else { return nil }
                    return name
                }
            )
        }
    }

    private func enabledValue(_ value: SystemProxyPropertyValue?) -> String {
        integerValue(value) == 1 ? "on" : "off"
    }

    private func integerValue(_ value: SystemProxyPropertyValue?) -> Int? {
        guard case let .integer(number) = value else { return nil }
        return Int(exactly: number)
    }

    private func stringValue(_ value: SystemProxyPropertyValue?) -> String? {
        guard case let .string(string) = value, !string.isEmpty else { return nil }
        return string
    }

    private func stringArrayValue(_ value: SystemProxyPropertyValue?) -> [String] {
        guard case let .array(values) = value else { return [] }
        return values.compactMap(stringValue)
    }
}

/// `networksetup -listallnetworkservices` launches a subprocess. System proxy
/// verification runs periodically, while the supported-name set changes only
/// when SystemConfiguration exposes a name not seen before. Cache both supported
/// and unsupported observed names so virtual adapters do not force a subprocess
/// on every guard pass.
private final class NetworkSetupServiceNameCache: @unchecked Sendable {
    private struct Snapshot {
        var observedNames: Set<String>
        var supportedNames: Set<String>
        var loadedAt: ContinuousClock.Instant
    }

    private let lock = NSLock()
    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var snapshot: Snapshot?
    private var generation: UInt64 = 0

    init(
        lifetime: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) {
        self.lifetime = lifetime < .zero ? .zero : lifetime
        self.now = now
    }

    func supportedNames(
        covering observedNames: Set<String>,
        load: () throws -> Set<String>
    ) throws -> Set<String> {
        while true {
            let requestedAt = now()
            let state = lock.withLock { (snapshot, generation) }
            if let cached = state.0 {
                let age = cached.loadedAt.duration(to: requestedAt)
                if age >= .zero,
                   age < lifetime,
                   observedNames.isSubset(of: cached.observedNames) {
                    return cached.supportedNames
                }
            }

            let loaded = try load()
            let installed = lock.withLock { () -> Set<String>? in
                guard generation == state.1 else { return nil }
                var allObservedNames = snapshot?.observedNames ?? []
                allObservedNames.formUnion(observedNames)
                let refreshed = Snapshot(
                    observedNames: allObservedNames,
                    supportedNames: loaded,
                    loadedAt: requestedAt
                )
                snapshot = refreshed
                return refreshed.supportedNames
            }
            if let installed { return installed }
        }
    }

    func invalidate() {
        lock.withLock {
            snapshot = nil
            generation &+= 1
        }
    }
}

private final class NetworkSetupWriter {
    private let runner: any NetworkSetupCommandRunning
    private var completedWrite = false

    init(runner: any NetworkSetupCommandRunning) {
        self.runner = runner
    }

    func run(_ arguments: [String]) throws {
        do {
            try runner.run(arguments)
            completedWrite = true
        } catch {
            guard completedWrite else { throw error }
            throw SystemProxyError.networkSetupFailed(error.localizedDescription)
        }
    }
}

protocol NetworkSetupCommandRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) throws -> String
}

struct ProcessNetworkSetupRunner: NetworkSetupCommandRunning {
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(filePath: "/usr/sbin/networksetup")
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SystemProxyError.networkSetupFailed(error.localizedDescription)
        }

        let output = String(
            decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let errorOutput = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let details = [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard process.terminationStatus == 0,
              !details.localizedCaseInsensitiveContains("requires admin privileges"),
              !details.localizedCaseInsensitiveContains("not a recognized network service"),
              !details.hasPrefix("** Error") else {
            if details.localizedCaseInsensitiveContains("requires admin privileges") {
                throw SystemProxyError.lockFailed
            }
            throw SystemProxyError.networkSetupFailed(
                details.isEmpty ? "networksetup exited with status \(process.terminationStatus)." : details
            )
        }
        return output
    }
}
#endif
