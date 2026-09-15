# Xray core notice

MClash bundles the official Xray-core macOS arm64 release under the Mozilla Public License 2.0. The full license is copied from the verified release archive in `LICENSE.md`.

The v26.9.9 tag resolves to `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`, but GitHub marks that release as pre-release. MClash pins v26.9.9 at commit `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120` (GitHub pre-release). The pinned archive SHA-256 is `b7cf765d60ccc703853d4218c49a1eacc5bca764543b9540bdeaf45c951afc7d`, and the extracted executable SHA-256 is `7616e4d8d5b8bedaee14ebe167954e24f35ccea58cdb941600e2ff76509fc31c`.

This release includes VLESS, VMess, Trojan, Shadowsocks, SOCKS, HTTP, WireGuard, and Hysteria2 support. Hysteria2 is gated by the JSON `protocol: "hysteria"` configuration with `settings.version: 2`; it uses QUIC transport and requires a Hysteria2 compatible server. The source contains `proxy/hysteria` and `transport/internet/hysteria`, so a blanket statement that Xray lacks Hysteria2 would be false.

The API service must include `RoutingService` and listen on a private local TCP address. Dynamic operations use `xray api lsi`, `xray api lso`, `xray api adrules`, `xray api ado`, `xray api adi`, and `xray api bo -b <balancer> <outboundTag>`. `xray api bo -r -b <balancer>` removes an override. These commands change future routing decisions; existing streams remain on their established outbound connection.
