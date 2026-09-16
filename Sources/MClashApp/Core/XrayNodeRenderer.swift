import Foundation
import MClashAutomationProtocol
import MClashNetworkShared

public enum XrayNodeRenderError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedProtocol(NodeProtocol)
    case unsupportedOption(String)
    case missingField(String)
    case invalidField(String)
    case removedInsecureTLS

    public var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(value): "Xray does not support this node protocol: \(value.rawValue)."
        case let .unsupportedOption(key): "This node option is not supported by the Xray adapter: \(key)."
        case let .missingField(key): "The node is missing \(key)."
        case let .invalidField(key): "The node has an invalid \(key)."
        case .removedInsecureTLS:
            """
            Xray removed the unverified TLS mode this node asks for with "skip-cert-verify". Pin the server \
            certificate with "pcs" ("pinnedPeerCertSha256"), or verify it with "vcn" \
            ("verifyPeerCertByName"), on this node instead.
            """
        }
    }
}

public enum XrayNodeRenderer {
    public static func render(_ node: Node, tag: String) throws -> AutomationJSONValue {
        guard (1...65535).contains(node.port), !node.host.isEmpty else { throw XrayNodeRenderError.invalidField("endpoint") }
        let parameters = try Parameters(NodeOnlyImporter().expandedParameters(node.parameters))
        for key in ["plugin", "obfs", "obfs-password", "ports", "hop-interval", "dialer-proxy"] {
            if let value = parameters[key], !value.isEmpty { throw XrayNodeRenderError.unsupportedOption(key) }
        }
        for key in ["udp-over-tcp", "smux.enabled", "mptcp"] where try parameters.bool(key, default: false) {
            throw XrayNodeRenderError.unsupportedOption(key)
        }
        var protocolName: String
        var settings: [String: AutomationJSONValue]
        let endpoint: [String: AutomationJSONValue] = ["address": .string(node.host), "port": .integer(Int64(node.port))]
        switch node.proto {
        case .vless, .vmess:
            protocolName = node.proto.rawValue
            let uuid = try parameters.required("uuid")
            guard UUID(uuidString: uuid) != nil else { throw XrayNodeRenderError.invalidField("uuid") }
            var user: [String: AutomationJSONValue] = ["id": .string(uuid), "level": .integer(0)]
            if node.proto == .vless {
                user["encryption"] = .string(parameters["encryption"] ?? "none")
                if let flow = parameters["flow"], !flow.isEmpty {
                    guard flow == "xtls-rprx-vision" || flow == "xtls-rprx-vision-udp443" else {
                        throw XrayNodeRenderError.unsupportedOption("flow")
                    }
                    user["flow"] = .string(flow)
                }
            } else {
                let alterID = parameters["alterid"] ?? parameters["alter-id"] ?? "0"
                guard alterID == "0" else { throw XrayNodeRenderError.unsupportedOption("alterId") }
                let cipher = parameters["cipher"] ?? "auto"
                guard ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"].contains(cipher) else {
                    throw XrayNodeRenderError.invalidField("cipher")
                }
                user["security"] = .string(cipher)
            }
            var server = endpoint
            server["users"] = .array([.object(user)])
            settings = ["vnext": .array([.object(server)])]
        case .trojan:
            protocolName = "trojan"
            var server = endpoint
            server["password"] = .string(try parameters.required("password"))
            settings = ["servers": .array([.object(server)])]
        case .http, .https, .socks5:
            protocolName = node.proto == .socks5 ? "socks" : "http"
            var server = endpoint
            if let username = parameters["username"] {
                server["users"] = .array([.object(["user": .string(username), "pass": .string(parameters["password"] ?? "")])])
            } else if parameters["password"] != nil {
                throw XrayNodeRenderError.missingField("username")
            }
            settings = ["servers": .array([.object(server)])]
        case .shadowsocks:
            protocolName = "shadowsocks"
            let method = try parameters.required("cipher")
            guard ["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
                   "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"].contains(method) else {
                throw XrayNodeRenderError.unsupportedOption("cipher")
            }
            var server = endpoint
            server["method"] = .string(method)
            server["password"] = .string(try parameters.required("password"))
            settings = ["servers": .array([.object(server)])]
        case .wireguard:
            protocolName = "wireguard"
            let secretKey = try parameters.wireGuardKey("secret-key", aliases: ["private-key", "privatekey"])
            let publicKey = try parameters.wireGuardKey("public-key", aliases: ["peer-public-key", "peer-publickey"])
            let addresses = try parameters.cidrList("address")
            let allowedIPs = try parameters.cidrList("allowed-ips")
            var peer: [String: AutomationJSONValue] = [
                "publicKey": .string(publicKey),
                "endpoint": .string(wireGuardEndpoint(host: node.host, port: node.port)),
                "allowedIPs": .array((allowedIPs.isEmpty ? ["0.0.0.0/0", "::/0"] : allowedIPs).map(AutomationJSONValue.string)),
            ]
            if let preSharedKey = try parameters.optionalWireGuardKey("pre-shared-key", aliases: ["psk", "presharedkey"]) {
                peer["preSharedKey"] = .string(preSharedKey)
            }
            if let keepAlive = try parameters.optionalInt("keep-alive", aliases: ["keepalive"], range: 0...65535) {
                peer["keepAlive"] = .integer(Int64(keepAlive))
            }
            var wireguard: [String: AutomationJSONValue] = [
                "secretKey": .string(secretKey),
                "peers": .array([.object(peer)]),
                "noKernelTun": .bool(try parameters.bool("no-kernel-tun", default: true)),
                "domainStrategy": .string(try parameters.wireGuardDomainStrategy()),
            ]
            if let mtu = try parameters.optionalInt("mtu", aliases: [], range: 576...65535) {
                wireguard["mtu"] = .integer(Int64(mtu))
            }
            let remoteDNS = try parameters.list("remote-dns")
            if !remoteDNS.isEmpty { wireguard["remoteDNS"] = .array(remoteDNS.map(AutomationJSONValue.string)) }
            if let reserved = try parameters.reservedBytes() {
                wireguard["reserved"] = .array(reserved.map { .integer(Int64($0)) })
            }
            if !addresses.isEmpty {
                wireguard["address"] = .array(addresses.map(AutomationJSONValue.string))
            }
            settings = wireguard
        case .hysteria2:
            protocolName = "hysteria"
            settings = endpoint
            settings["version"] = .integer(2)
        default:
            throw XrayNodeRenderError.unsupportedProtocol(node.proto)
        }
        var result: [String: AutomationJSONValue] = ["tag": .string(tag), "protocol": .string(protocolName), "settings": .object(settings)]
        if node.proto != .wireguard {
            result["streamSettings"] = .object(try transport(node, parameters: parameters))
        }
        return .object(result)
    }

    private static func wireGuardEndpoint(host: String, port: Int) -> String {
        let endpointHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(endpointHost):\(port)"
    }

    private static func transport(_ node: Node, parameters p: Parameters) throws -> [String: AutomationJSONValue] {
        let requestedNetwork = p["network"] ?? (node.proto == .hysteria2 ? "hysteria" : "tcp")
        let network = requestedNetwork == "tcp" ? "raw" : requestedNetwork
        guard ["raw", "ws", "grpc", "httpupgrade", "xhttp", "hysteria"].contains(network) else {
            throw XrayNodeRenderError.unsupportedOption("network")
        }
        guard network != "hysteria" || node.proto == .hysteria2 else { throw XrayNodeRenderError.invalidField("network") }
        var stream: [String: AutomationJSONValue] = ["network": .string(network),
            "sockopt": .object(["domainStrategy": .string("ForceIP")])]
        let realityKey = p["reality-opts.public-key"] ?? p["reality-public-key"]
        let serverName = p["servername"] ?? p["sni"] ?? node.host
        if let realityKey {
            guard node.proto == .vless, network == "raw" || network == "grpc" || network == "xhttp" else {
                throw XrayNodeRenderError.unsupportedOption("reality-opts")
            }
            let decoded = Data(base64Encoded: realityKey.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - realityKey.count % 4) % 4))
            guard decoded?.count == 32 else { throw XrayNodeRenderError.invalidField("reality-opts.public-key") }
            let shortID = p["reality-opts.short-id"] ?? ""
            guard shortID.count <= 16, shortID.count % 2 == 0, shortID.allSatisfy({ $0.isHexDigit }) else {
                throw XrayNodeRenderError.invalidField("reality-opts.short-id")
            }
            let spider = p["reality-opts.spider-x"] ?? "/"
            guard spider.hasPrefix("/") else { throw XrayNodeRenderError.invalidField("reality-opts.spider-x") }
            stream["security"] = .string("reality")
            stream["realitySettings"] = .object([
                "serverName": .string(serverName), "publicKey": .string(realityKey), "shortId": .string(shortID),
                "spiderX": .string(spider), "fingerprint": .string(p["client-fingerprint"] ?? "chrome"),
            ])
        } else if try p.bool("tls", default: [.trojan, .https, .hysteria2].contains(node.proto)) {
            var tls: [String: AutomationJSONValue] = ["serverName": .string(serverName)]
            let alpn = try p.list("alpn")
            if !alpn.isEmpty { tls["alpn"] = .array(alpn.map(AutomationJSONValue.string)) }
            if let fingerprint = p["client-fingerprint"] { tls["fingerprint"] = .string(fingerprint) }
            // Xray dropped "allowInsecure"; a node that wants to skip verification must pin the peer
            // certificate or name it instead, and is unusable until it does.
            let pinned = try p.certificatePins()
            let verifyNames = try p.verifyNames()
            if !pinned.isEmpty { tls["pinnedPeerCertSha256"] = .string(pinned.joined(separator: ",")) }
            if !verifyNames.isEmpty { tls["verifyPeerCertByName"] = .string(verifyNames.joined(separator: ",")) }
            if try p.bool("skip-cert-verify", default: false), pinned.isEmpty, verifyNames.isEmpty {
                throw XrayNodeRenderError.removedInsecureTLS
            }
            stream["security"] = .string("tls")
            stream["tlsSettings"] = .object(tls)
        } else if node.proto == .hysteria2 {
            throw XrayNodeRenderError.invalidField("tls")
        }
        switch network {
        case "ws", "httpupgrade":
            let prefix = network == "ws" ? "ws-opts" : "http-upgrade-opts"
            var path = p[prefix + ".path"] ?? p["path"] ?? "/"
            guard path.hasPrefix("/") else { throw XrayNodeRenderError.invalidField(prefix + ".path") }
            if let early = p[prefix + ".max-early-data"] {
                guard let size = Int(early), (0...65536).contains(size) else { throw XrayNodeRenderError.invalidField("max-early-data") }
                let header = p[prefix + ".early-data-header-name"] ?? "Sec-WebSocket-Protocol"
                guard header.lowercased() == "sec-websocket-protocol" else { throw XrayNodeRenderError.unsupportedOption("early-data-header-name") }
                if size > 0 { path += (path.contains("?") ? "&" : "?") + "ed=\(size)" }
            }
            var options: [String: AutomationJSONValue] = ["path": .string(path)]
            var headers: [String: AutomationJSONValue] = [:]
            for (key, value) in p.values where key.hasPrefix(prefix + ".headers.") {
                let name = String(key.dropFirst((prefix + ".headers.").count))
                if name == "host" { options["host"] = .string(value) } else { headers[name] = .string(value) }
            }
            if let host = p["host"], options["host"] == nil { options["host"] = .string(host) }
            if !headers.isEmpty { options["headers"] = .object(headers) }
            stream[network == "ws" ? "wsSettings" : "httpupgradeSettings"] = .object(options)
        case "grpc":
            let service = p["grpc-opts.grpc-service-name"] ?? p["service-name"] ?? ""
            stream["grpcSettings"] = .object(["serviceName": .string(service)])
        case "xhttp":
            stream["xhttpSettings"] = .object(["path": .string(p["xhttp-opts.path"] ?? "/"),
                "host": .string(p["xhttp-opts.host"] ?? serverName), "mode": .string(p["xhttp-opts.mode"] ?? "auto")])
        case "hysteria":
            stream["hysteriaSettings"] = .object(["version": .integer(2), "auth": .string(try p.required("password", alias: "auth"))])
        default:
            break
        }
        var socketOptions: [String: AutomationJSONValue] = [:]
        if try p.bool("tfo", default: false) { socketOptions["tcpFastOpen"] = .bool(true) }
        if let strategy = p["ip-version"] {
            let strategies = ["dual": "UseIP", "ipv4": "ForceIPv4", "ipv6": "ForceIPv6",
                              "ipv4-prefer": "UseIPv4v6", "ipv6-prefer": "UseIPv6v4"]
            guard let value = strategies[strategy] else { throw XrayNodeRenderError.invalidField("ip-version") }
            socketOptions["domainStrategy"] = .string(value)
        }
        if !socketOptions.isEmpty { stream["sockopt"] = .object(socketOptions) }
        return stream
    }

    private struct Parameters {
        let values: [String: String]

        init(_ input: [String: String]) throws {
            let keys: Set<String> = [
                "uuid", "password", "auth", "username", "encryption", "flow", "cipher", "alterid", "alter-id",
                "network", "tls", "servername", "sni", "skip-cert-verify", "client-fingerprint", "alpn",
                "pinned-peer-cert-sha256", "pinnedpeercertsha256", "pcs",
                "verify-peer-cert-by-name", "verifypeercertbyname", "vcn",
                "udp", "tfo", "mptcp", "ip-version", "plugin", "obfs", "obfs-password", "ports", "hop-interval",
                "dialer-proxy", "udp-over-tcp", "smux.enabled", "path", "host", "service-name",
                "secret-key", "private-key", "privatekey", "public-key", "publickey", "peer-public-key", "peer-publickey",
                "address", "addresses", "allowed-ips", "allowedips", "pre-shared-key", "presharedkey", "psk",
                "keep-alive", "keepalive", "mtu", "no-kernel-tun", "domain-strategy", "domainstrategy", "remote-dns", "dns", "reserved",
                "ws-opts.path", "ws-opts.max-early-data", "ws-opts.early-data-header-name",
                "http-upgrade-opts.path", "http-upgrade-opts.max-early-data", "http-upgrade-opts.early-data-header-name",
                "grpc-opts.grpc-service-name", "reality-opts.public-key", "reality-public-key", "reality-opts.short-id",
                "reality-opts.spider-x", "xhttp-opts.path", "xhttp-opts.host", "xhttp-opts.mode",
            ]
            var normalized: [String: String] = [:]
            for (key, value) in input {
                let canonical = NodeIdentity.normalizeParameterKey(key)
                guard keys.contains(canonical) || canonical.hasPrefix("alpn[") || canonical.hasPrefix("ws-opts.headers.")
                    || canonical.hasPrefix("http-upgrade-opts.headers.") else {
                    throw XrayNodeRenderError.unsupportedOption(canonical)
                }
                if let old = normalized[canonical], old != value { throw XrayNodeRenderError.invalidField(canonical) }
                normalized[canonical] = value
            }
            values = normalized
        }

        subscript(_ key: String) -> String? { values[key] }

        func required(_ key: String, alias: String? = nil) throws -> String {
            guard let value = self[key] ?? alias.flatMap({ self[$0] }), !value.isEmpty else {
                throw XrayNodeRenderError.missingField(key)
            }
            return value
        }

        func bool(_ key: String, default fallback: Bool) throws -> Bool {
            guard let value = self[key] else { return fallback }
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: throw XrayNodeRenderError.invalidField(key)
            }
        }

        func list(_ key: String) throws -> [String] {
            if let value = self[key] {
                if value.hasPrefix("[") {
                    guard let data = value.data(using: .utf8), let result = try? JSONDecoder().decode([String].self, from: data) else {
                        throw XrayNodeRenderError.invalidField(key)
                    }
                    return result
                }
                return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return values.keys.filter { $0.hasPrefix(key + "[") }.sorted().compactMap { values[$0] }
        }

        func cidrList(_ key: String) throws -> [String] {
            let values = try list(key)
            guard values.allSatisfy({ (try? IPNetwork($0)) != nil }) else {
                throw XrayNodeRenderError.invalidField(key)
            }
            return values
        }

        func wireGuardDomainStrategy() throws -> String {
            switch (self["domain-strategy"] ?? "forceip").lowercased() {
            case "forceip": return "ForceIP"
            case "forceipv4": return "ForceIPv4"
            case "forceipv6": return "ForceIPv6"
            case "forceipv4v6": return "ForceIPv4v6"
            case "forceipv6v4": return "ForceIPv6v4"
            default: throw XrayNodeRenderError.invalidField("domain-strategy")
            }
        }

        func wireGuardKey(_ key: String, aliases: [String]) throws -> String {
            guard let value = try optionalWireGuardKey(key, aliases: aliases) else {
                throw XrayNodeRenderError.missingField(key)
            }
            return value
        }

        func optionalWireGuardKey(_ key: String, aliases: [String]) throws -> String? {
            guard let value = self[key] ?? aliases.compactMap({ self[$0] }).first else { return nil }
            guard !value.isEmpty else { throw XrayNodeRenderError.invalidField(key) }
            if value.count == 64, value.allSatisfy({ $0.isHexDigit }) { return value }
            var encoded = value
            encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            let decoded = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
            guard decoded?.count == 32 else { throw XrayNodeRenderError.invalidField(key) }
            return value
        }

        func optionalInt(_ key: String, aliases: [String], range: ClosedRange<Int>) throws -> Int? {
            guard let value = self[key] ?? aliases.compactMap({ self[$0] }).first else { return nil }
            guard let parsed = Int(value), range.contains(parsed) else { throw XrayNodeRenderError.invalidField(key) }
            return parsed
        }

        func reservedBytes() throws -> [Int64]? {
            guard let value = self["reserved"] else { return nil }
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let bytes = parts.compactMap(Int.init)
            guard parts.count == 3, bytes.count == 3,
                  bytes.allSatisfy({ (0...255).contains($0) }) else {
                throw XrayNodeRenderError.invalidField("reserved")
            }
            return bytes.map(Int64.init)
        }

        /// Several subscriptions spell the same pinned-certificate option differently.
        func firstValue(of keys: [String]) throws -> String? {
            var found: String?
            for key in keys {
                guard let value = self[key] else { continue }
                if let found, found != value { throw XrayNodeRenderError.invalidField(key) }
                found = value
            }
            return found
        }

        /// Xray takes the leaf hashes as one comma-separated hex string.
        func certificatePins() throws -> [String] {
            guard let value = try firstValue(of: ["pinned-peer-cert-sha256", "pinnedpeercertsha256", "pcs"]) else {
                return []
            }
            return try value.split(separator: ",").map { entry in
                let hash = entry.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "").lowercased()
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
                    throw XrayNodeRenderError.invalidField("pinned-peer-cert-sha256")
                }
                return hash
            }
        }

        func verifyNames() throws -> [String] {
            guard let value = try firstValue(of: ["verify-peer-cert-by-name", "verifypeercertbyname", "vcn"]) else {
                return []
            }
            let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { throw XrayNodeRenderError.invalidField("verify-peer-cert-by-name") }
            return names
        }
    }
}
