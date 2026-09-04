import Foundation

/// Validated Reality/XTLS material carried by an imported VLESS target.
/// This is metadata validation only; no uTLS or Xray handshake is provided.
public struct RealityConfiguration: Codable, Equatable, Sendable {
    public let publicKey: String
    public let shortID: String
    public let serverName: String
    public let fingerprint: String?
    public let flow: String?
    public let spiderX: String

    public init(parameters: [String: String]) throws {
        let values = Dictionary(uniqueKeysWithValues: parameters.map {
            ($0.key.lowercased().replacingOccurrences(of: "_", with: "-"), $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let reality = values["reality-opts"] ?? values["reality-options"]
        func nested(_ key: String) -> String? {
            guard let reality else { return nil }
            return reality.split(separator: ",").first { $0.split(separator: "=", maxSplits: 1).first?.lowercased() == key }
                .flatMap { $0.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) }
        }
        let publicKey = values["public-key"] ?? nested("public-key")
        let shortID = values["short-id"] ?? nested("short-id")
        let serverName = values["servername"] ?? values["server-name"] ?? values["sni"]
        guard let publicKey, Self.isValidPublicKey(publicKey) else { throw RealityConfigurationError.invalidPublicKey }
        let shortID = shortID ?? ""
        guard Self.isValidShortID(shortID) else { throw RealityConfigurationError.invalidShortID }
        guard let serverName, !serverName.isEmpty, serverName.utf8.count <= 255 else { throw RealityConfigurationError.invalidServerName }
        let fingerprint = values["fingerprint"] ?? values["client-fingerprint"]
        if let fingerprint, !Self.allowedFingerprints.contains(fingerprint.lowercased()) { throw RealityConfigurationError.invalidFingerprint }
        let flow = values["flow"]
        if let flow, !Self.allowedFlows.contains(flow.lowercased()) { throw RealityConfigurationError.invalidFlow }
        let spiderX = values["spiderx"] ?? values["spider-x"] ?? "/"
        if !spiderX.hasPrefix("/") || spiderX.contains(where: { $0 == "\r" || $0 == "\n" }) { throw RealityConfigurationError.invalidSpiderX }
        self.publicKey = publicKey; self.shortID = shortID; self.serverName = serverName
        self.fingerprint = fingerprint; self.flow = flow; self.spiderX = spiderX
    }

    static let allowedFingerprints: Set<String> = ["chrome", "firefox", "safari", "ios", "android", "edge", "qq", "random"]
    static let allowedFlows: Set<String> = ["", "xtls-rprx-vision", "xtls-rprx-vision-udp443", "xtls-rprx-direct"]
    static func isValidShortID(_ value: String) -> Bool {
        let chars = Array(value.lowercased())
        return chars.count <= 16 && chars.count % 2 == 0 && chars.allSatisfy { $0.isHexDigit }
    }
    static func isValidPublicKey(_ value: String) -> Bool {
        guard value.count == 43,
              !value.contains("=") else { return false }
        var padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded)?.count == 32
    }
}

public enum RealityConfigurationError: Error, Codable, Equatable, Sendable {
    case invalidPublicKey, invalidShortID, invalidServerName, invalidFingerprint, invalidFlow, invalidSpiderX
}
