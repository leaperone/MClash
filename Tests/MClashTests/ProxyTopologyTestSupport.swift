import Foundation
@testable import MClashApp

struct ProxyTestSpec {
    let name: String
    let type: String
    var all: [String] = []
    var now: String?
    var fixed: String?
    var dialerProxy: String?
    var providerName: String?
    var hidden = false
    var alive = true
}

func makeProxyCollection(_ specs: [ProxyTestSpec]) throws -> MihomoProxyCollection {
    var proxies: [String: Any] = [:]
    for spec in specs {
        var proxy: [String: Any] = [
            "name": spec.name,
            "type": spec.type,
            "all": spec.all,
            "hidden": spec.hidden,
            "alive": spec.alive,
        ]
        if let now = spec.now { proxy["now"] = now }
        if let fixed = spec.fixed { proxy["fixed"] = fixed }
        if let dialerProxy = spec.dialerProxy { proxy["dialer-proxy"] = dialerProxy }
        if let providerName = spec.providerName { proxy["provider-name"] = providerName }
        proxies[spec.name] = proxy
    }
    let data = try JSONSerialization.data(withJSONObject: ["proxies": proxies])
    return try JSONDecoder().decode(MihomoProxyCollection.self, from: data)
}
