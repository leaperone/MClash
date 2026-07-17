# TUN implementation boundary

MClash must not enable mihomo TUN by patching the current user-owned core process. On macOS, route, DNS, and interface changes need a separately signed privileged service with deterministic cleanup. A plain settings toggle would work only on some machines and could leave networking broken after a crash.

## Chosen architecture

1. Ship a separately signed `MClashTunnelService` launch daemon inside the app bundle and register it with `SMAppService`.
2. Move ownership of the TUN-mode mihomo process to that service. The normal user process remains owned by `CoreSupervisor`; only one owner may run at a time.
3. Expose a narrow XPC protocol: service status, install/register, start from a validated app-owned configuration identifier, stop, and restore network state. Do not accept arbitrary executable paths, shell commands, controller secrets, or configuration bytes from untrusted clients.
4. Verify the connecting client audit token, bundle identifier, Team ID, and designated requirement before accepting a request.
5. Persist the pre-TUN route and DNS recovery record with mode `0600` before starting. On startup and shutdown, restore an unfinished record before accepting another TUN session.
6. Keep the Alpha controller bound to loopback with an ephemeral secret. Return only the loopback endpoint and session state to the main app.

## Configuration to expose after the service exists

- Enable TUN
- Stack: `system`, `gvisor`, or `mixed`
- Device name
- Auto route and strict route
- Auto-detect outbound interface
- DNS hijack targets
- MTU
- Included/excluded interfaces
- Included/excluded IPv4 and IPv6 route ranges
- Endpoint-independent NAT and UDP timeout

The values should become an optional authoritative `tun` section in `RuntimeOverrides`, using the same staging, exact-final-YAML validation, atomic activation, and rollback pipeline as DNS. The UI must keep the TUN switch disabled until the signed service reports ready.

## Required verification

- Unit tests for XPC authorization and request validation
- Service integration tests for start/stop serialization and crash recovery records
- A VM/manual matrix for Wi-Fi, Ethernet, sleep/wake, network changes, app force-quit, service crash, OS restart, and uninstall
- Developer ID signing/notarization verification for both executables and the embedded daemon property list

Until this boundary is implemented and signed, MClash intentionally does not offer a partial TUN toggle.
