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
