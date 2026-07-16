import Foundation
import Testing
@testable import MClashApp

@Suite("Mihomo Alpha models")
struct MihomoModelsTests {
    @Test
    func decodesAlphaConfigResponse() throws {
        let data = Data(
            #"""
            {
              "port": 7890,
              "socks-port": 7891,
              "redir-port": 0,
              "tproxy-port": 0,
              "mixed-port": 7893,
              "tun": {
                "enable": false,
                "device": "utun0",
                "stack": "Mixed",
                "dns-hijack": ["any:53"],
                "auto-route": true,
                "auto-detect-interface": true,
                "mtu": 9000,
                "strict-route": true,
                "route-address": ["0.0.0.0/1"],
                "route-exclude-address": ["192.168.0.0/16"]
              },
              "authentication": [],
              "skip-auth-prefixes": ["127.0.0.0/8"],
              "lan-allowed-ips": ["0.0.0.0/0"],
              "lan-disallowed-ips": [],
              "allow-lan": false,
              "bind-address": "*",
              "mode": "rule",
              "unified-delay": true,
              "log-level": "info",
              "ipv6": true,
              "interface-name": "",
              "routing-mark": 0,
              "geox-url": {
                "geo-ip": "https://example.com/geoip.dat",
                "mmdb": "https://example.com/country.mmdb",
                "asn": "https://example.com/asn.mmdb",
                "geo-site": "https://example.com/geosite.dat"
              },
              "geo-auto-update": false,
              "geo-update-interval": 24,
              "geodata-mode": true,
              "geodata-loader": "memconservative",
              "geosite-matcher": "succinct",
              "tcp-concurrent": true,
              "find-process-mode": "strict",
              "sniffing": true,
              "global-ua": "clash.meta",
              "etag-support": true,
              "keep-alive-idle": 15,
              "keep-alive-interval": 15,
              "disable-keep-alive": false
            }
            """#.utf8
        )

        let config = try JSONDecoder().decode(MihomoConfig.self, from: data)

        #expect(config.mixedPort == 7893)
        #expect(config.mode == "rule")
        #expect(config.tcpConcurrent)
        #expect(config.tun.stack == "Mixed")
        #expect(config.tun.routeExcludeAddresses == ["192.168.0.0/16"])
        #expect(config.geoXURL?.geoSite == "https://example.com/geosite.dat")
    }

    @Test
    func decodesProxyGroupsIncludingAlphaExtraHistory() throws {
        let data = Data(
            #"""
            {
              "proxies": {
                "Auto": {
                  "name": "Auto",
                  "type": "URLTest",
                  "udp": true,
                  "uot": false,
                  "xudp": true,
                  "tfo": true,
                  "mptcp": false,
                  "smux": false,
                  "alive": true,
                  "history": [{"time":"2026-07-16T08:00:00.123456+08:00","delay":42}],
                  "extra": {
                    "https://cp.cloudflare.com/generate_204": {
                      "alive": true,
                      "history": [{"time":"2026-07-16T08:00:00+08:00","delay":39}]
                    }
                  },
                  "all": ["Hong Kong", "DIRECT"],
                  "now": "Hong Kong",
                  "testUrl": "https://cp.cloudflare.com/generate_204",
                  "expectedStatus": "204",
                  "fixed": "",
                  "hidden": false,
                  "icon": "https://example.com/icon.png",
                  "emptyFallback": "COMPATIBLE",
                  "interface": "",
                  "routing-mark": 0,
                  "provider-name": "provider-a",
                  "dialer-proxy": ""
                }
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(MihomoProxyCollection.self, from: data)
        let group = try #require(response.proxies["Auto"])

        #expect(group.type == "URLTest")
        #expect(group.now == "Hong Kong")
        #expect(group.history.first?.delay == 42)
        #expect(
            group.extraDelayHistories["https://cp.cloudflare.com/generate_204"]?.history?.first?.delay == 39
        )
    }

    @Test
    func classifiesProxyGroupBehaviorsAndOverrideCapabilities() throws {
        let data = Data(
            #"""
            {
              "proxies": {
                "Manual": {"name":"Manual","type":"Selector"},
                "Auto": {"name":"Auto","type":"URLTest","fixed":""},
                "Fallback": {"name":"Fallback","type":"Fallback"},
                "Balanced": {"name":"Balanced","type":"LoadBalance"},
                "Node": {"name":"Node","type":"Shadowsocks"}
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(MihomoProxyCollection.self, from: data)

        #expect(response.proxies["Manual"]?.groupBehavior == .selector)
        #expect(response.proxies["Auto"]?.groupBehavior == .urlTest)
        #expect(response.proxies["Auto"]?.fixedOverride == nil)
        #expect(response.proxies["Fallback"]?.groupBehavior == .fallback)
        #expect(response.proxies["Balanced"]?.groupBehavior == .loadBalance)
        #expect(response.proxies["Node"]?.groupBehavior == nil)

        #expect(ProxyGroupBehavior.selector.supportsSelectionUpdate)
        #expect(!ProxyGroupBehavior.selector.supportsClearingOverride)
        #expect(ProxyGroupBehavior.urlTest.supportsSelectionUpdate)
        #expect(ProxyGroupBehavior.urlTest.supportsClearingOverride)
        #expect(ProxyGroupBehavior.fallback.supportsSelectionUpdate)
        #expect(ProxyGroupBehavior.fallback.supportsClearingOverride)
        #expect(!ProxyGroupBehavior.loadBalance.supportsSelectionUpdate)
        #expect(!ProxyGroupBehavior.loadBalance.supportsClearingOverride)
    }

    @Test
    func decodesRulesIncludingAlphaExtraMetadata() throws {
        let data = Data(
            #"""
            {
              "rules": [{
                "index": 0,
                "type": "DomainSuffix",
                "payload": "example.com",
                "proxy": "Proxy",
                "size": -1,
                "extra": {
                  "disabled": false,
                  "hitCount": 4,
                  "hitAt": "2026-07-16T08:00:00+08:00",
                  "missCount": 2,
                  "missAt": "2026-07-16T08:01:00+08:00"
                }
              }]
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(MihomoRuleCollection.self, from: data)
        let rule = try #require(response.rules.first)

        #expect(rule.type == "DomainSuffix")
        #expect(rule.payload == "example.com")
        #expect(rule.size == -1)
        #expect(rule.extra?.hitCount == 4)
        #expect(rule.extra?.missAt == "2026-07-16T08:01:00+08:00")
    }

    @Test
    func decodesRuleWithoutOptionalWrapperMetadata() throws {
        let data = Data(
            #"{"rules":[{"index":1,"type":"Match","payload":"","proxy":"DIRECT","size":-1}]}"#.utf8
        )

        let response = try JSONDecoder().decode(MihomoRuleCollection.self, from: data)

        #expect(response.rules.first?.extra == nil)
        #expect(response.rules.first?.proxy == "DIRECT")
    }

    @Test
    func decodesProxyProvidersAndSubscriptionMetadata() throws {
        let data = Data(
            #"""
            {
              "providers": {
                "provider-a": {
                  "name": "provider-a",
                  "type": "Proxy",
                  "vehicleType": "HTTP",
                  "proxies": [{
                    "name": "Node A",
                    "type": "Shadowsocks",
                    "alive": true,
                    "history": []
                  }],
                  "testUrl": "https://cp.cloudflare.com/generate_204",
                  "expectedStatus": "204",
                  "updatedAt": "2026-07-16T08:00:00+08:00",
                  "subscriptionInfo": {
                    "Upload": 1024,
                    "Download": 2048,
                    "Total": 107374182400,
                    "Expire": 1784160000
                  }
                }
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(MihomoProxyProviderCollection.self, from: data)
        let provider = try #require(response.providers["provider-a"])

        #expect(provider.vehicleType == "HTTP")
        #expect(provider.proxies.first?.name == "Node A")
        #expect(provider.testURL == "https://cp.cloudflare.com/generate_204")
        #expect(provider.subscriptionInfo?.download == 2048)
        #expect(provider.subscriptionInfo?.total == 107_374_182_400)
    }

    @Test
    func decodesCompatibleProxyProviderWithoutOptionalMetadata() throws {
        let data = Data(
            #"{"providers":{"default":{"name":"default","type":"Proxy","vehicleType":"Compatible","proxies":[],"testUrl":"","expectedStatus":""}}}"#.utf8
        )

        let response = try JSONDecoder().decode(MihomoProxyProviderCollection.self, from: data)
        let provider = try #require(response.providers["default"])

        #expect(provider.updatedAt == nil)
        #expect(provider.subscriptionInfo == nil)
        #expect(provider.vehicleType == "Compatible")
    }

    @Test
    func decodesRuleProvidersIncludingInlinePayload() throws {
        let data = Data(
            #"""
            {
              "providers": {
                "rules-a": {
                  "behavior": "Domain",
                  "format": "Yaml",
                  "name": "rules-a",
                  "ruleCount": 123,
                  "type": "Rule",
                  "vehicleType": "HTTP",
                  "updatedAt": "2026-07-16T08:00:00+08:00"
                },
                "inline": {
                  "behavior": "Classical",
                  "format": "",
                  "name": "inline",
                  "ruleCount": 2,
                  "type": "Rule",
                  "vehicleType": "Inline",
                  "updatedAt": "2026-07-16T08:02:00+08:00",
                  "payload": ["DOMAIN,example.com", "MATCH"]
                }
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(MihomoRuleProviderCollection.self, from: data)

        #expect(response.providers["rules-a"]?.ruleCount == 123)
        #expect(response.providers["rules-a"]?.payload == nil)
        #expect(response.providers["inline"]?.format == "")
        #expect(response.providers["inline"]?.payload == ["DOMAIN,example.com", "MATCH"])
    }

    @Test
    func decodesConnectionSnapshotAndTraffic() throws {
        let connectionData = Data(
            #"""
            {
              "downloadTotal": 2048,
              "uploadTotal": 1024,
              "memory": 8388608,
              "connections": [{
                "id": "CB47B2E6-3142-4A53-9E70-1E7372EE77B3",
                "metadata": {
                  "network": "tcp",
                  "type": "HTTPS",
                  "sourceIP": "127.0.0.1",
                  "destinationIP": "1.1.1.1",
                  "sourcePort": "55221",
                  "destinationPort": "443",
                  "host": "example.com",
                  "process": "Safari",
                  "processPath": "/Applications/Safari.app/Contents/MacOS/Safari"
                },
                "upload": 512,
                "download": 1024,
                "start": "2026-07-16T08:00:00.123456+08:00",
                "chains": ["Hong Kong", "Proxy"],
                "providerChains": ["provider-a"],
                "rule": "DomainSuffix",
                "rulePayload": "example.com"
              }]
            }
            """#.utf8
        )
        let trafficData = Data(#"{"up":12,"down":34,"upTotal":1024,"downTotal":2048}"#.utf8)

        let snapshot = try JSONDecoder().decode(MihomoConnectionSnapshot.self, from: connectionData)
        let traffic = try JSONDecoder().decode(MihomoTraffic.self, from: trafficData)

        #expect(snapshot.connections.first?.metadata.host == "example.com")
        #expect(snapshot.connections.first?.chains == ["Hong Kong", "Proxy"])
        #expect(traffic.upload == 12)
        #expect(traffic.downloadTotal == 2048)
    }

    @Test
    func configPatchOmitsUnspecifiedFields() throws {
        let patch = MihomoConfigPatch(
            allowLAN: false,
            mode: "global",
            tcpConcurrent: true
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any]
        )

        #expect(object["allow-lan"] as? Bool == false)
        #expect(object["mode"] as? String == "global")
        #expect(object["tcp-concurrent"] as? Bool == true)
        #expect(object["mixed-port"] == nil)
        #expect(object["tun"] == nil)
    }
}
