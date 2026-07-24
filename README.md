# MClash

MClash is a native macOS controller for the
[MetaCubeX mihomo Alpha](https://github.com/MetaCubeX/mihomo/tree/Alpha) core.
It bundles and supervises the core, manages Clash-compatible profiles, and
provides System Proxy and per-application routing without exposing routine core
maintenance to the user.

MClash is a controller, not a proxy service. You need your own compatible YAML
profile or subscription.

## Highlights

- Native SwiftUI and AppKit interface, main window, and menu bar controls
- Interface languages: English, Simplified and Traditional Chinese, Japanese,
  Korean, French, German, and Spanish, with a System Default option
- Bundled, checksum-verified mihomo Alpha core and GEO databases
- Local YAML profiles and remote subscriptions with validation, transactional
  activation, rollback, scheduled refresh, and bounded retry backoff
- Rule, Global, and Direct modes with searchable proxy groups, latency tests,
  nested-route inspection, topology view, and customizable Quick Routes
- Safe macOS System Proxy activation with complete snapshot and restoration of
  the previous HTTP, HTTPS, SOCKS, PAC, auto-discovery, and bypass settings
- Per-application TCP and UDP routing through a signed macOS Network Extension
- Live traffic, connection history, rules, providers, logs, routing evidence,
  and actionable health diagnostics
- Recovery after sleep, wake, network changes, or a bounded core failure
- Signed Sparkle updates and a versioned local automation API

## Requirements

- macOS 14 or later
- Apple Silicon for published releases
- A Clash/mihomo-compatible local profile or subscription

The repository contains architecture-selection support for Intel, but an Intel
release is not produced until its mihomo artifact has an independently reviewed
hash in the manifest.

## Install

1. Download the current Apple Silicon DMG from
   [GitHub Releases](https://github.com/leaperone/MClash/releases/latest).
2. Open the DMG and move **MClash** to **Applications**.
3. Launch MClash. Keep the app in `/Applications` so its signed helper, Network
   Extension, and automatic updates retain a stable identity.

Published builds are Developer ID signed, notarized by Apple, and updated from
the signed Sparkle feed. The mihomo executable and GEO data are already included;
end users do not download or select a core.

## Get started

1. Open **Profiles** and choose **Import & Activate** for a local YAML file, or
   **Add Subscription** for an HTTP/HTTPS subscription.
2. Select the default profile, optionally enable additional Profile sessions,
   and connect. Each enabled Profile has its own Mihomo process and Mixed port.
3. Choose how macOS traffic should enter MClash:

   - Enable **Use macOS System Proxy** for ordinary proxy-aware applications.
   - Open **App Routing** to send selected applications or destinations through
     Mihomo while leaving other applications direct.
   - Leave both off when you only need the local Mixed listeners shown by
     MClash. Each Mixed port accepts HTTP, HTTPS proxy, and SOCKS5 clients.

4. Select Rule, Global, or Direct mode and, when applicable, choose the desired
   policy-group route.

Choose **Settings → Appearance → Language** to override the macOS language, or
leave **System Default** selected.

MClash validates the generated runtime configuration with `mihomo -t` before
activation without rewriting the stored profile. For predictable multi-profile
isolation, each managed session exposes only its MClash-assigned Mixed port and
private App Routing listeners. Profile-owned HTTP/SOCKS/Mixed/custom listeners,
TUN, tunnels, server shortcuts, and external controllers are not launched;
advanced Redirect, TProxy, and DNS settings remain available on the default
profile.

## App Routing

App Routing uses a macOS app-proxy Network Extension to evaluate traffic before
it reaches Mihomo. The first enabled matching rule wins. If no rule is enabled,
application traffic is explicitly Direct. DNS routing has its own on/off state
and runs through the companion DNS Proxy provider.

A rule can match:

- one or more signed applications, application/bundle identifier patterns,
  executables, running process instances, or user IDs;
- exact domains, domain suffixes, wildcard hostname patterns, IP addresses, or
  CIDR networks; and
- TCP, UDP, and destination port ranges.

A match can go Direct, be rejected, follow a selected Profile's rules, use that
Profile's Mihomo GLOBAL route, or enter a specific policy group on the default
Profile. Each rule also defines what to do if its requested Profile or route is
unavailable. Rules can be reordered, disabled, duplicated, and updated
transactionally. Existing Proxifier `.ppx` routing rules can be previewed and
selectively imported; proxy servers, credentials, and chains are not imported.

For predictable rules, prefer a selected signed application over a broad name
pattern, keep one application or intent per rule, enable UDP when the application
uses QUIC or calls, and place narrow exceptions above broad fallbacks. The
**Activity** and **Traffic** views show the application-to-rule-to-proxy path
that MClash actually observed.

The first App Routing activation may require approval of the system extension
and network configuration in macOS. If macOS reports that a restart is required,
restart the Mac before trying again.

## Automation API

Release builds include a signed `mclashctl` helper at
`MClash.app/Contents/Helpers/mclashctl`. It starts MClash in the background when
needed, discovers the current user's private Unix socket, sends one JSON-RPC
request, and prints one JSON-RPC response to stdout.

```sh
/Applications/MClash.app/Contents/Helpers/mclashctl capabilities --pretty
/Applications/MClash.app/Contents/Helpers/mclashctl status --pretty
/Applications/MClash.app/Contents/Helpers/mclashctl core.connect
/Applications/MClash.app/Contents/Helpers/mclashctl routing.mode.set \
  --params '{"mode":"rule"}'
```

For a stable shell command, link the helper instead of copying it:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/MClash.app/Contents/Helpers/mclashctl ~/.local/bin/mclashctl
```

`system.capabilities` is the authoritative operation list for the installed
version. The API covers app and core lifecycle, profiles and backups, settings,
routing and proxy selection, Mihomo rules/providers, System Proxy, App Routing,
traffic/history, logs, and diagnostics.

### Trusted local clients

The local pairing dialog offers two explicit choices:

- **Allow Needed Access** grants only the scopes needed by the commands a client
  has requested. New scopes can prompt again, and every destructive operation
  still requires a fresh local confirmation naming the exact operation.
- **Trust This Client** grants the identified client all automation scopes for
  180 days. It removes later pairing dialogs and permits destructive operations
  to run unattended during that period. This is intentionally broad authority,
  not a convenience alias for standard scoped access.

Both choices are limited to the same macOS user and bound to the client's code
identity. Trust can be listed or revoked with `auth.clients.*`, and an identity
change invalidates it. With standard access, `--allow-interaction` permits
MClash to show a required local confirmation; it never approves the operation
by itself.

The bundled CLI is a same-user broker: any process under the same macOS login
that can run it can use the authority granted to that helper. Choosing **Trust
This Client** for `mclashctl` therefore also allows those processes to invoke
unattended destructive operations. Use **Allow Needed Access** for least
privilege, or an independently signed native client when separate tools need
separate trust identities. Tokens are stored in the client's Keychain; MClash
stores only their SHA-256 hashes.

The endpoint does not listen on TCP or LAN. It accepts the same macOS user only,
binds authorization to the client's code identity, and does not return the
Mihomo controller secret, Network Extension credentials, or full subscription
URLs. See [Automation API v1](docs/AUTOMATION.md) for the protocol, scopes,
idempotency rules, CLI options, and complete operation families.

## Development

Development requires Xcode with the macOS SDK and Swift 6. From the repository
root:

```sh
./scripts/typecheck.sh
./scripts/test-direct.sh
./scripts/integration-test.sh
./scripts/build-app.sh
open .build/release/MClash.app
```

`build-app.sh` creates an ad-hoc-signed local application by default. It fetches
Sparkle tools and immutable build inputs when needed, verifies the selected
mihomo artifact and GEO databases, and assembles the host app, `mclashctl`, and
Network Extension. A production-capable Network Extension build requires the
Developer ID identity, provisioning profiles, and entitlements used by the
protected release workflow.

The standalone Command Line Tools installation on some machines has a SwiftPM
`PackageDescription` interface/dylib mismatch. `scripts/typecheck.sh` and
`scripts/test-direct.sh` provide direct compiler/test paths; CI uses `swift test`
with a complete Xcode toolchain.

Useful verification commands:

```sh
./scripts/verify-mihomo-alpha.sh
./scripts/verify-mihomo-geodata.sh .build/release/MClash.app/Contents/Resources/GeoData
```

The pinned core version and commit live in `Support/mihomo-alpha.env`; reviewed
raw executable hashes live in `Support/mihomo-alpha.sha256`. Production builds
also bundle verified `geoip.metadb`, `GeoIP.dat`, `GeoSite.dat`, and `ASN.mmdb`.

### Repository layout

| Path | Purpose |
| --- | --- |
| `Sources/MClashApp` | macOS application, UI, core/profile management, System Proxy, and automation server |
| `Sources/MClashNetworkExtension` | App Routing and DNS Network Extension providers |
| `Sources/MClashNetworkShared` | Shared capture-rule, flow, relay, and process-identity models |
| `Sources/MClashAutomationProtocol` | JSON-RPC protocol and Unix-socket client |
| `Sources/MClashCLI` | `mclashctl` command-line client |
| `Tests` | Unit, Network Extension, protocol, and integration coverage |
| `Support` | Plists, entitlements, release inputs, and bundled-artifact manifests |
| `scripts` | Local build, test, artifact verification, packaging, and release tooling |
| `docs` | Automation and release documentation |

## Security and privacy

- The Mihomo controller binds to a dynamic `127.0.0.1` port and uses a random
  per-launch secret retained only for the current MClash process.
- The automation endpoint is a mode-0600, per-user Unix socket. It checks the
  peer UID, client identity, token, and authorized access before dispatch.
- Profile changes are validated before activation and use transactional rollback.
- MClash snapshots all relevant macOS proxy settings before changing them and
  restores the snapshot on disable, disconnect, quit, update, or recovery.
- Diagnostics redact credentials, bearer tokens, sensitive query values, and
  subscription details before export.
- Backups are intentionally unencrypted and may contain subscription URLs and
  proxy credentials. Store them as secrets.
- Core updates arrive as part of a signed MClash release; MClash does not use
  Mihomo's in-place `/upgrade` endpoint.
- TUN mode is not currently exposed. Its design requires a separately signed,
  narrow privileged helper rather than arbitrary root shell execution.

Report suspected vulnerabilities privately through GitHub's **Report a
vulnerability** form. Do not attach real subscriptions, credentials, logs, or
backup archives to a public issue. See [Privacy](PRIVACY.md) and the
[Security Policy](SECURITY.md).

## Releases

Production releases are built by the protected GitHub Actions release workflow.
It runs the test suite, verifies dependencies, signs with the hardened runtime,
notarizes and staples the app and DMG, signs Sparkle full and delta updates, and
publishes checksums and corresponding third-party source material.

Maintainers publish a semantic tag such as `v1.2.3`; end users receive signed
updates in the app. See [Releasing MClash](docs/RELEASING.md) for required
secrets, build-number policy, published assets, and the complete procedure.

## Documentation

- [Product principles](PRODUCT.md)
- [Interface design system](DESIGN.md)
- [Automation API v1](docs/AUTOMATION.md)
- [Release candidate test plan](MANUAL_TEST_PLAN.md)
- [Release process](docs/RELEASING.md)
- [TUN implementation boundary](TUN_IMPLEMENTATION.md)
- [Security policy](SECURITY.md)
- [Privacy](PRIVACY.md)
- [mihomo distribution notice](ThirdParty/mihomo/NOTICE.md)

## License

MClash source is available for inspection under the
[MClash Source Code License](LICENSE); it is not an open-source license.
Bundled third-party components remain under their own licenses and notices.
