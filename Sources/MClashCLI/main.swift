import AppKit
import Foundation
import MClashAutomationProtocol
import Security

@main
struct MClashCLI {
    static func main() {
        var diagnosticRequestID: String?
        do {
            let invocation = try Invocation(arguments: Array(CommandLine.arguments.dropFirst()))
            let discovery = try loadDiscovery(invocation: invocation)
            let client: AutomationSocketClient
            if invocation.socketPath != nil {
                client = AutomationSocketClient(
                    unsafeDevelopmentSocketPath: discovery.socketPath
                )
            } else {
                let expectedExecutablePath = try applicationURL()
                    .appendingPathComponent("Contents/MacOS/MClash")
                    .standardizedFileURL.path
                client = AutomationSocketClient(
                    socketPath: discovery.socketPath,
                    expectedProcessIdentifier: discovery.processIdentifier,
                    expectedSigningIdentifier: "one.leaper.mclash",
                    expectedTeamIdentifier: AutomationCodeSignature
                        .currentProcessTeamIdentifier(),
                    expectedExecutablePath: expectedExecutablePath
                )
            }
            let requestID = invocation.requestID ?? UUID().uuidString
            diagnosticRequestID = requestID
            var token = invocation.socketPath == nil
                ? try? AutomationTokenKeychain.load()
                : nil
            var request = AutomationRPCRequest(
                id: requestID,
                method: invocation.method,
                params: invocation.parameters,
                allowInteraction: invocation.allowInteraction,
                authorization: token
            )
            let requestTimeout = invocation.requiresInteractiveTimeout
                ? max(invocation.timeout, 300)
                : invocation.timeout
            var response = try client.send(request, timeout: requestTimeout)
            if let responseType = response.error?.type,
               ["authentication_required", "scope_required", "authorization_failed"]
                .contains(responseType),
               invocation.method != "auth.pair" {
                let requiredScope = try requiredScope(
                    for: invocation.method,
                    response: response,
                    client: client
                )
                let pairing = AutomationRPCRequest(
                    method: "auth.pair",
                    params: [
                        "name": .string("mclashctl"),
                        "scopes": .array([.string(requiredScope.rawValue)]),
                    ],
                    allowInteraction: true
                )
                let pairingResponse = try client.send(pairing, timeout: 300)
                guard pairingResponse.error == nil,
                      case let .object(pairingResult)? = pairingResponse.result,
                      let pairedToken = pairingResult["token"]?.stringValue else {
                    response = pairingResponse
                    try printResponse(response, pretty: invocation.pretty)
                    Foundation.exit(2)
                }
                if invocation.socketPath == nil {
                    try AutomationTokenKeychain.save(pairedToken)
                }
                token = pairedToken
                request = AutomationRPCRequest(
                    id: requestID,
                    method: invocation.method,
                    params: invocation.parameters,
                    allowInteraction: invocation.allowInteraction,
                    authorization: token
                )
                response = try client.send(request, timeout: requestTimeout)
            }
            try printResponse(response, pretty: invocation.pretty)
            if response.error != nil { Foundation.exit(2) }
        } catch InvocationError.help {
            print(Invocation.usage)
        } catch {
            var payload: [String: String] = [
                "type": "client_error",
                "message": error.localizedDescription,
            ]
            if let diagnosticRequestID {
                payload["requestID"] = diagnosticRequestID
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(payload) {
                FileHandle.standardError.write(data)
                FileHandle.standardError.write(Data([0x0A]))
            }
            Foundation.exit(1)
        }
    }

    private static func printResponse(
        _ response: AutomationRPCResponse,
        pretty: Bool
    ) throws {
            let encoder = JSONEncoder.automation
            encoder.outputFormatting = pretty
                ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                : [.sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func requiredScope(
        for method: String,
        response: AutomationRPCResponse,
        client: AutomationSocketClient
    ) throws -> AutomationClientScope {
        if case let .object(data)? = response.error?.data,
           let rawScope = data["requiredScope"]?.stringValue,
           let scope = AutomationClientScope(rawValue: rawScope) {
            return scope
        }
        let capabilitiesResponse = try client.send(
            AutomationRPCRequest(method: "system.capabilities"),
            timeout: 30
        )
        guard capabilitiesResponse.error == nil,
              case let .array(capabilities)? = capabilitiesResponse.result,
              let capability = capabilities.first(where: {
                  $0.objectValue?["method"]?.stringValue == method
              }),
              let rawScope = capability.objectValue?["requiredScope"]?.stringValue,
              let scope = AutomationClientScope(rawValue: rawScope) else {
            throw CLIError.invalidArguments(
                "Could not discover the required scope for \(method)"
            )
        }
        return scope
    }

    private static func loadDiscovery(invocation: Invocation) throws
        -> AutomationEndpointDiscovery
    {
        if let socketPath = invocation.socketPath {
            return AutomationEndpointDiscovery(
                processIdentifier: 0,
                socketPath: socketPath,
                nonce: "explicit",
                appVersion: "unknown"
            )
        }
        do {
            return try AutomationDiscovery.load()
        } catch where !invocation.noLaunch {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--mclash-background"]
            let applicationURL = try applicationURL()
            let semaphore = DispatchSemaphore(value: 0)
            let launchResult = LaunchResultBox()
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                launchResult.setError(error)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                throw CLIError.invalidArguments("MClash launch timed out")
            }
            if let launchError = launchResult.getError() { throw launchError }
            let deadline = Date().addingTimeInterval(invocation.timeout)
            while Date() < deadline {
                if let endpoint = try? AutomationDiscovery.load() { return endpoint }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw error
        }
    }

    private static func applicationURL() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let candidate = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if candidate.pathExtension == "app" { return candidate }
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "one.leaper.mclash"
        ) {
            return url
        }
        throw CLIError.applicationNotInstalled
    }
}

private final class LaunchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func setError(_ value: Error?) {
        lock.withLock { error = value }
    }

    func getError() -> Error? {
        lock.withLock { error }
    }
}

private enum AutomationTokenKeychain {
    private static let service = "one.leaper.mclash.automation"
    private static let account = "mclashctl"

    private static var key: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    static func load() throws -> String? {
        var query = key
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw CLIError.keychain(status)
        }
        return token
    }

    static func save(_ token: String) throws {
        let key = key
        let values: [CFString: Any] = [
            kSecValueData: Data(token.utf8),
            kSecAttrLabel: "MClash Automation Client Token",
        ]
        let updateStatus = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = key
            values.forEach { add[$0.key] = $0.value }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw CLIError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw CLIError.keychain(updateStatus)
        }
    }
}

private struct Invocation {
    let method: String
    let parameters: [String: AutomationJSONValue]
    let allowInteraction: Bool
    let pretty: Bool
    let noLaunch: Bool
    let socketPath: String?
    let timeout: TimeInterval
    let requestID: String?

    static let usage = """
    Usage: mclashctl <method|status|capabilities> [options]

      --params <json>         JSON object passed as RPC params
      --params-stdin          Read the JSON params object from standard input
      --params-file <path>    Read the JSON params object from a file
      --allow-interaction     Allow MClash to present required local UI
      --pretty                Pretty-print the JSON response
      --no-launch             Do not launch MClash when it is not running
      --socket <path>         Connect to an explicit Unix socket (development)
      --timeout <seconds>     Request/startup timeout (default: 60)
      --request-id <id>       Stable 1...128-byte ID for safe mutation retries
      --help                  Show this help

    Examples:
      mclashctl status --pretty
      mclashctl core.connect
      mclashctl routing.mode.set --params '{"mode":"rule"}'
      mclashctl traffic.connections.closeAll --allow-interaction
    """

    init(arguments: [String]) throws {
        guard let command = arguments.first, command != "--help", command != "-h" else {
            throw InvocationError.help
        }
        method = switch command {
        case "status": "system.snapshot"
        case "capabilities": "system.capabilities"
        default: command
        }
        var parsedParameters: [String: AutomationJSONValue] = [:]
        var parsedAllowInteraction = false
        var parsedPretty = false
        var parsedNoLaunch = false
        var parsedSocketPath: String?
        var parsedTimeout: TimeInterval = 60
        var parsedRequestID: String?
        var parsedParameterSource = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--params":
                guard !parsedParameterSource else {
                    throw CLIError.invalidArguments("Choose only one params input")
                }
                parsedParameterSource = true
                index += 1
                guard index < arguments.count,
                      let data = arguments[index].data(using: .utf8) else {
                    throw CLIError.invalidArguments("--params must be a JSON object")
                }
                parsedParameters = try Self.decodeParameters(data, option: "--params")
            case "--params-stdin":
                guard !parsedParameterSource else {
                    throw CLIError.invalidArguments("Choose only one params input")
                }
                parsedParameterSource = true
                parsedParameters = try Self.decodeParameters(
                    try Self.readBounded(FileHandle.standardInput),
                    option: "--params-stdin"
                )
            case "--params-file":
                guard !parsedParameterSource else {
                    throw CLIError.invalidArguments("Choose only one params input")
                }
                parsedParameterSource = true
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--params-file requires a path")
                }
                let file = try FileHandle(forReadingFrom: URL(
                    fileURLWithPath: arguments[index]
                ))
                defer { try? file.close() }
                parsedParameters = try Self.decodeParameters(
                    try Self.readBounded(file),
                    option: "--params-file"
                )
            case "--allow-interaction": parsedAllowInteraction = true
            case "--pretty": parsedPretty = true
            case "--no-launch": parsedNoLaunch = true
            case "--socket":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--socket requires a path")
                }
                parsedSocketPath = arguments[index]
            case "--timeout":
                index += 1
                guard index < arguments.count,
                      let value = TimeInterval(arguments[index]), value > 0, value <= 300 else {
                    throw CLIError.invalidArguments("--timeout must be between 0 and 300 seconds")
                }
                parsedTimeout = value
            case "--request-id":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArguments("--request-id requires a value")
                }
                let value = arguments[index]
                guard !value.isEmpty, value.utf8.count <= 128 else {
                    throw CLIError.invalidArguments(
                        "--request-id must contain 1...128 UTF-8 bytes"
                    )
                }
                parsedRequestID = value
            default:
                throw CLIError.invalidArguments("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        parameters = parsedParameters
        allowInteraction = parsedAllowInteraction
        pretty = parsedPretty
        noLaunch = parsedNoLaunch
        socketPath = parsedSocketPath
        timeout = parsedTimeout
        requestID = parsedRequestID
    }

    private static func readBounded(_ file: FileHandle) throws -> Data {
        let maximum = MClashAutomationProtocol.maximumFrameSize - 16 * 1_024
        var data = Data()
        while let chunk = try file.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else {
                throw CLIError.invalidArguments("Params input is too large")
            }
        }
        return data
    }

    private static func decodeParameters(
        _ data: Data,
        option: String
    ) throws -> [String: AutomationJSONValue] {
        guard case let .object(object) = try JSONDecoder.automation.decode(
            AutomationJSONValue.self,
            from: data
        ) else {
            throw CLIError.invalidArguments("\(option) must contain a JSON object")
        }
        return object
    }

    var requiresInteractiveTimeout: Bool {
        allowInteraction || [
            "profiles.importInteractive",
            "backup.exportInteractive",
            "backup.restoreInteractive",
            "app.update.check",
        ].contains(method)
    }
}

private enum InvocationError: Error {
    case help
}

private enum CLIError: Error, LocalizedError {
    case invalidArguments(String)
    case applicationNotInstalled
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        case .applicationNotInstalled:
            "MClash.app could not be found. Open MClash once or use --socket."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }
}
