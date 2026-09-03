import Foundation
import MClashNetworkShared
@preconcurrency import Network
import Testing
@testable import MClashNetworkExtension

@Suite("Native real endpoint interoperability")
struct NativeRealEndpointInteropTests {
    @Test("VLESS WebSocket carries HTTPS through an MClash HTTP entrance")
    func vlessWebSocketCarriesHTTPS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["MCLASH_REAL_PROFILE_MANIFEST"] else {
            return
        }
        let nodeHint = environment["MCLASH_REAL_NODE_NAME_CONTAINS"]
            ?? "🇺🇸 美国|us|9929|ws|private"
        let target = try Self.loadVLESSWebSocketTarget(
            manifestURL: URL(fileURLWithPath: manifestPath),
            nameContains: nodeHint
        )
        guard OutboundConnectorCapabilityMatrix.support(for: target) == .native else {
            throw RealEndpointProbeError.nodeIsNotNativeVLESSWebSocket
        }

        let route = OutboundRoute.group("real-endpoint-probe")
        let catalog = try OutboundNodeTargetCatalog(entries: [
            OutboundNodeTargetEntry(route: route, target: target)
        ])
        let readiness = ListenerReadiness()
        let listener = try MClashInboundListener(
            kind: .httpConnect,
            port: 0,
            route: { _ in .proxy(route.stableSortKey) },
            connector: NativeInboundCatalogConnector(catalog: catalog),
            stateHandler: { ready, port in readiness.update(ready: ready, port: port) }
        )
        listener.start()
        defer { listener.stop() }

        let deadline = ContinuousClock.now + .seconds(5)
        while readiness.port == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let port = readiness.port else {
            throw RealEndpointProbeError.listenerDidNotStart
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent",
            "--show-error",
            "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "--proxy", "http://127.0.0.1:\(port)",
            "--connect-timeout", "15",
            "--max-time", "30",
            "https://www.google.com/generate_204"
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let status = process.terminationStatus
        let responseCode = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RealEndpointProbeError.curlFailed(
                status: status,
                detail: String(detail.prefix(512))
            )
        }
        #expect(responseCode == "204")
    }

    private static func loadVLESSWebSocketTarget(
        manifestURL: URL,
        nameContains hint: String
    ) throws -> OutboundNodeTarget {
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard data.count <= 32 * 1_024 * 1_024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]] else {
            throw RealEndpointProbeError.invalidManifest
        }
        for node in nodes {
            guard let name = node["displayName"] as? String,
                  name.localizedCaseInsensitiveContains(hint),
                  node["proto"] as? String == "vless",
                  let host = node["host"] as? String,
                  let portNumber = node["port"] as? NSNumber,
                  let port = UInt16(exactly: portNumber.intValue),
                  let rawParameters = node["parameters"] as? [String: Any]
            else { continue }
            let parameters = rawParameters.reduce(into: [String: String]()) {
                result, element in
                if let value = element.value as? String {
                    result[element.key] = value
                }
            }
            guard parameters["network"]?.lowercased() == "ws" else { continue }
            return try OutboundNodeTarget(
                protocolName: "vless",
                host: host,
                port: port,
                parameters: parameters
            )
        }
        throw RealEndpointProbeError.nodeNotFound
    }
}

private final class ListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(ready: Bool, port: UInt16?) {
        lock.lock()
        value = ready ? port : nil
        lock.unlock()
    }
}

private enum RealEndpointProbeError: Error, LocalizedError {
    case invalidManifest
    case nodeNotFound
    case nodeIsNotNativeVLESSWebSocket
    case listenerDidNotStart
    case curlFailed(status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The real-endpoint probe manifest is invalid or too large."
        case .nodeNotFound:
            "The requested VLESS WebSocket node was not found."
        case .nodeIsNotNativeVLESSWebSocket:
            "The requested node is not classified as native VLESS WebSocket."
        case .listenerDidNotStart:
            "The temporary MClash HTTP entrance did not start."
        case let .curlFailed(status, detail):
            "The HTTPS probe failed with curl status \(status): \(detail)"
        }
    }
}
