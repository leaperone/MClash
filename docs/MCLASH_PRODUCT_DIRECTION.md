# MClash product direction

MClash presents one simple idea to ordinary users. Add node sources, choose how traffic should be connected, and see the route that MClash observed.

## Add nodes

Node sources include subscriptions, local files, and pasted share links. Pasted input can contain VLESS, VMess, Trojan, Shadowsocks, HTTP, SOCKS5, Hysteria2, WireGuard links, native WireGuard configuration text, or a Base64 node list. Remote sources use the same bounded link decoder when their response is not YAML. The import sheet previews usable nodes, ignored lines, detected formats, and diagnostics before it writes a source.

The parser stores credentials only in the private node source. Diagnostics and list rows never include credentials. A pasted source persists as its own source and refresh does not erase the user's groups or rules.

## Routing model

MClash owns the configuration model. Sources provide node connection data. The user chooses a simple route mode and a node group. Advanced selectors, health thresholds, DNS choices, listeners, and application rules appear under Advanced settings.

Xray-core handles protocol connections and outbound transport. It does not own the user-facing configuration model, import flow, groups, or traffic history.

## Traffic evidence

MClash records App Routing activities with the source application, destination, rule decision, relay state, timing, and measured bytes when the system extension owns the flow.

Xray exposes aggregate byte totals. Xray 1.6 does not expose a per-connection list through its control API. MClash therefore shows its own flow records for Xray mode and labels aggregate Xray counters separately. It never renders an empty core connection list as proof that no traffic exists.

A route view can show the configured path and the observed path. Unknown values stay unknown. A direct handoff does not become zero bytes, and an Xray aggregate does not become a fabricated per-flow node.

## Compatibility language

The product uses user terms such as node source, connection mode, node group, traffic rule, DNS, and flow record. Core names remain in diagnostics and developer documentation only when they explain a compatibility boundary.

## Release gates

Every product change needs a direct Swift test run, a signed app build, an isolated traffic smoke, and a clean source check. Public endpoint tests are recorded separately from local fixtures. The installed production application remains untouched during local acceptance.
