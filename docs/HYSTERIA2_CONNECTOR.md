# Native Hysteria2 connector

Hysteria2 is not a SOCKS5-over-UDP transport. A native connector must preserve
the protocol layers below, in order:

1. QUIC client transport with the configured congestion/packet options.
2. TLS certificate validation and the Hysteria2 ALPN/server-name contract.
3. Password authentication as specified by the Hysteria2 client/server
   handshake (never reuse the node identity hash as a password).
4. HTTP/3 control stream and CONNECT-UDP request framing.
5. Per-flow UDP association lifecycle, backpressure, cancellation, and byte
   accounting.

The MClash connector boundary must expose these as an outbound session, not as
a local listener or a routing decision. DIRECT and REJECT never reach this
stack. Mihomo/Xray source is used only as an interoperability reference; each
implemented layer needs a golden vector or a live test against a compatible
Hysteria2 endpoint before becoming the default.

Current status: the shared node target/catalog and connector interfaces are in
place. HTTP CONNECT, SOCKS5, DNS UDP/TCP, VLESS TCP, and Trojan TCP codecs have
independent tests. QUIC/HTTP3 framing is intentionally not marked implemented
until the wire-level vectors and cancellation behavior are covered.
