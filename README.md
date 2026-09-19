# MClash

MClash 1.6 is a native macOS proxy app built around [Xray-core](https://github.com/XTLS/Xray-core).
MClash manages node sources, groups, routing rules, DNS and traffic records.
Xray handles proxy connections. You supply your own nodes or subscription.

[中文使用指南](docs/GETTING_STARTED_1_6.md)

## Highlights

- Paste node links, encoded node lists or WireGuard configuration, import a file, or add a subscription.
- Start with a default node group, then choose manual selection, automatic latency selection, fallback, load balancing or relay.
- Keep your groups and routing rules when sources refresh.
- Use local rules, bundled domain and country databases, or online rule lists checked before each update.
- Choose local HTTP/SOCKS access, macOS System Proxy or selected applications through a signed Network Extension.
- Inspect recorded destinations and readable paths, with detailed information available on selection.
- Recover the proxy and its connection monitor after an unexpected core exit.
- Use a native SwiftUI interface, menu bar controls and progressively disclosed advanced settings.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- A supported proxy node, node file or subscription.

## Install

1. Download the Apple Silicon DMG from [GitHub Releases](https://github.com/leaperone/MClash/releases).
2. Open the DMG and move **MClash** to **Applications**.
3. Launch MClash. Keep it in `/Applications` for its signed helper, Network Extension and updates.

Published builds include the proxy core and routing databases. Developer ID signing,
Apple notarization and signed Sparkle updates are part of the distribution process.

## Get started

1. Open **Node Sources** and paste links, import a file or add a subscription.
2. Check the imported nodes and connect. The default group includes newly imported nodes.
3. Open **How to Connect** to choose local proxy access, System Proxy or application routing.
4. Use **Nodes** to change selection behavior and **Rules** to choose which traffic uses each group.

Imports provide nodes. MClash owns the groups, rules, DNS and listeners used by the
running app. You do not need to maintain a core configuration file.

**Connection Log** shows observed events rather than a count of active sockets.
Select a record to inspect its source, protocol and path. An event does not prove
that a remote site responded successfully. Application traffic and byte totals
are reported only where MClash can observe them.

## Application routing

Application routing uses a macOS Network Extension. Rules can match signed
applications, executable paths, domains, IP networks, protocols and ports.
Matched traffic can go directly, be rejected or use a node group. macOS may require
approval when the extension is first enabled or upgraded.

DNS has its own configuration. Fake-IP mode maps synthetic addresses back to the
requested domain before the proxy connects. Node endpoints use real DNS resolution.

Online rule lists update every six hours or when requested. MClash validates new
rules before applying them and keeps the previous rules if download or validation
fails. Online lists use the target you choose in MClash.

## Automation API

Release builds include a signed `mclashctl` helper at
`MClash.app/Contents/Helpers/mclashctl`. It starts MClash in the background when
needed, discovers the current user's private Unix socket, sends one JSON-RPC
request, and prints one JSON-RPC response to stdout.

In **Settings → Advanced**, choose **Install Command Line Tool** to create
`~/.local/bin/mclashctl`. MClash must be directly inside `/Applications`; it
links to that trusted helper and never replaces an existing file or different
link. Add `~/.local/bin` to your shell or agent `PATH` if it is not already present.

```sh
mclashctl capabilities --pretty
mclashctl status --pretty
mclashctl core.connect
mclashctl routing.mode.set --params '{"mode":"rule"}'
```

`system.capabilities` is the authoritative operation list for the installed
version. The API covers app and core lifecycle, profiles and backups, settings,
routing and proxy selection, unified Configuration planning and activation,
routing rules and sources, System Proxy, application routing, traffic history, logs, and
diagnostics. If moving MClash leaves an old command link, follow the verified
`readlink` and `unlink` recovery in [Automation API v1](docs/AUTOMATION.md);
do not overwrite it with `ln -sf`.

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
runtime credentials, Network Extension credentials, or full subscription
URLs. See [Automation API v1](docs/AUTOMATION.md) for the protocol, scopes,
idempotency rules, CLI options, and complete operation families.

## Development

Development requires Xcode with the macOS SDK and Swift 6. From the repository
root:

```sh
./scripts/typecheck.sh
./scripts/test-direct.sh
./scripts/fetch-xray.sh
CONFIGURATION=development MCLASH_VERSION=1.6.0-dev MCLASH_RUNTIME_BACKEND=xray ./scripts/build-app.sh
python3 scripts/smoke-test-xray-app.py .build/development/MClash.app --output .build/app-proof.json --exercise-recovery --exercise-log-retention
```

`build-app.sh` creates an ad-hoc-signed local application by default. It fetches
Sparkle tools and immutable build inputs when needed, verifies the selected
Xray artifact and routing databases, and assembles the host app, `mclashctl`, and
Network Extension. A production-capable Network Extension build requires the
Developer ID identity, provisioning profiles, and entitlements used by the
protected release workflow.

The standalone Command Line Tools installation on some machines has a SwiftPM
`PackageDescription` interface/dylib mismatch. `scripts/typecheck.sh` and
`scripts/test-direct.sh` provide direct compiler/test paths; CI uses `swift test`
with a complete Xcode toolchain.

Useful verification commands:

```sh
./scripts/verify-xray.sh
./scripts/verify-xray-geodata.sh .build/development/MClash.app/Contents/Resources/GeoData
python3 scripts/test-xray-package-layout.py .build/development/MClash.app
```

The core version, revision and reviewed hashes are pinned in `Support/xray.env`.
Application packages contain Xray and its verified `geoip.dat` and `geosite.dat`.
The smoke fixture uses private storage and local test servers. UI checks require
an unlocked macOS session and accessibility access.

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

- Xray control uses a private Unix socket managed by MClash.
- The automation endpoint is a mode-0600, per-user Unix socket. It checks the
  peer UID, client identity, token, and authorized access before dispatch.
- Profile changes are validated before activation and use transactional rollback.
- MClash snapshots all relevant macOS proxy settings before changing them and
  restores the snapshot on disable, disconnect, quit, update, or recovery.
- Diagnostics redact credentials, bearer tokens, sensitive query values, and
  subscription details before export.
- Backups are intentionally unencrypted and may contain subscription URLs and
  proxy credentials. Store them as secrets.
- Core updates arrive with a signed MClash release.
- macOS traffic capture uses the signed Network Extension.

Report suspected vulnerabilities privately through GitHub's **Report a
vulnerability** form. Do not attach real subscriptions, credentials, logs, or
backup archives to a public issue. See [Privacy](PRIVACY.md) and the
[Security Policy](SECURITY.md).

## Releases

Production releases are built by the protected GitHub Actions release workflow.
It runs the test suite, verifies dependencies, signs with the hardened runtime,
notarizes and staples the app and DMG, signs Sparkle full and delta updates, and
publishes checksums and third-party notices.

Maintainers validate the complete signed candidate before publishing one semantic tag; end users receive signed
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
- [Xray distribution notice](ThirdParty/xray/NOTICE.md)

## License

MClash source is available for inspection under the
[MClash Source Code License](LICENSE); it is not an open-source license.
Bundled third-party components remain under their own licenses and notices.
