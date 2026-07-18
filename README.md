# MClash

MClash is a native macOS controller for the
[MetaCubeX mihomo Alpha](https://github.com/MetaCubeX/mihomo/tree/Alpha) core.
The application is written with SwiftUI and AppKit. The Go core remains an
isolated process and is controlled through its authenticated loopback REST and
WebSocket API.

## Current scope

- Native window and dedicated menu bar quick-control popup
- Responsive native layouts with wide-screen dashboard composition, compact
  fallbacks, and consistent system backgrounds across every destination
- Alpha core discovery, configuration validation, lifecycle supervision, and
  bounded crash recovery
- Per-launch in-memory local controller secret (no connection-time Keychain prompt)
- Local and remote profile storage with transactional activation and rollback
- Rule / Global / Direct routing with YAML-stable policy-group ordering,
  searchable node selection, latency testing, nested dependency topology, and
  current-path inspection
- Session-scoped routing explanations that connect observed domains and rules
  to the actual group-to-node chain reported by mihomo
- Rules, proxy providers, rule providers, live connections, logs, and traffic
- Shared numeric formatting for rates, byte totals, memory, and localized counts
- REST/WebSocket API models, authenticated client, and stream reconnection
- Complete macOS proxy snapshots with `networksetup` activation and rollback
- Runtime-managed local listener fallback for subscriptions that omit HTTP/SOCKS ports
- Dynamic loopback controller port to avoid conflicts with other Clash/mihomo clients
- Optional automatic connection reset after routing mode or node changes
- Signed Sparkle updates from GitHub Releases with automatic checking,
  background downloads, and user-approved installation and relaunch
- Versioned local JSON-RPC automation with a signed, bundled `mclashctl` for
  AI agents, scripts, and other same-user tools

TUN mode will be implemented behind a signed, narrow XPC privileged helper. It
is intentionally not handled through arbitrary shell commands or a root-owned
general-purpose launcher.

## Requirements

- macOS 14 or later
- Xcode with the macOS SDK for normal development
- Swift 6

The current machine's standalone Command Line Tools installation has a known
SwiftPM `PackageDescription` interface/dylib mismatch. `scripts/typecheck.sh`
therefore provides a direct compiler verification path until full Xcode is
selected.

## Development

```sh
cd ~/CodingSpace/MClash
./scripts/typecheck.sh
./scripts/test-direct.sh
./scripts/integration-test.sh
./scripts/build-app.sh
open .build/release/MClash.app
```

The user-driven release candidate checklist is in
[`MANUAL_TEST_PLAN.md`](MANUAL_TEST_PLAN.md). It deliberately keeps UI and
network-setting validation manual while automated tests cover data, state, API,
profile transaction, and proxy restoration behavior.

`build-app.sh` automatically downloads the architecture-appropriate Alpha core,
verifies its upstream archive checksum and recorded unpacked SHA-256, and embeds
it in the application as `mclash-mihomo`. End users never select or download a
core.

## Automation API

Release builds include `MClash.app/Contents/Helpers/mclashctl`. The CLI starts
MClash in the background when needed, discovers its private per-user Unix
socket, and prints one JSON-RPC response to stdout:

```sh
/Applications/MClash.app/Contents/Helpers/mclashctl capabilities --pretty
/Applications/MClash.app/Contents/Helpers/mclashctl status --pretty
/Applications/MClash.app/Contents/Helpers/mclashctl core.connect
/Applications/MClash.app/Contents/Helpers/mclashctl routing.mode.set \
  --params '{"mode":"rule"}'
```

For a stable shell command, link—not copy—the signed helper:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/MClash.app/Contents/Helpers/mclashctl ~/.local/bin/mclashctl
```

`system.capabilities` is the authoritative, machine-readable operation list.
It covers application/window lifecycle, settings and updates, core lifecycle,
profiles and backups, runtime overrides, routing and proxy selection, Mihomo
rules/providers, System Proxy, App Routing, connections/history, logs, and
diagnostics. Destructive operations fail with `confirmation_required` unless
the caller passes `--allow-interaction`; MClash then shows a local one-time
approval dialog naming the exact operation.

On first use, `mclashctl` asks MClash to pair locally. The approval dialog shows
the executable identity and requested scopes; the resulting 256-bit token is
kept in the caller's macOS Keychain, while MClash stores only its SHA-256 hash.
Tokens are bound to the client's code identity, expire after 180 days, and can
be listed or revoked through `auth.clients.*`.

The bundled CLI is a user-level broker: granting `mclashctl` a scope allows
processes under the same macOS login to invoke that scope through the helper.
Agents that require separate trust identities should use independently signed
native clients. Stable `--request-id` values make mutation recovery idempotent;
secret parameters can be supplied with `--params-stdin` or `--params-file`.

The endpoint never listens on TCP or LAN, accepts only paired clients with the
same macOS user ID, and does not expose the Mihomo controller secret, Network
Extension credentials, or full subscription URLs. Read calls return cached
state and freshness metadata, so a background AI client does not reactivate
the high-frequency UI telemetry streams. Protocol and command details are in
[`docs/AUTOMATION.md`](docs/AUTOMATION.md).

## Bundled mihomo Alpha artifact

MClash currently pins `alpha-a70af27` at commit
`a70af27451ac6837bcbbd3c542d8207304096e2f` from the upstream
`Prerelease-Alpha` channel. Release metadata lives in `Support/mihomo-alpha.env`; SHA-256 values for
the unpacked, executable artifacts live in `Support/mihomo-alpha.sha256`.

Both Apple Silicon and Intel use the same artifact-selection code. The first
release target is Apple Silicon; every supported architecture must have a
separately reviewed raw hash in the manifest before its core can be fetched.
The reviewed Apple Silicon artifact is committed as an explicit release input
because the upstream Alpha release tag is mutable. It is verified against the
recorded unpacked SHA-256 before every application build and integration run:

```sh
./scripts/verify-mihomo-alpha.sh
./scripts/verify-mihomo-alpha.sh --architecture x86_64
```

The second command intentionally fails until an independently reviewed Intel
hash and artifact are added in a dedicated release change.

`fetch-mihomo-alpha.sh` is a guarded recovery path for as long as the pinned
asset remains available upstream. It never follows the moving `version.txt`,
verifies the selected archive against upstream `checksums.txt`, and refuses to
replace an artifact unless its unpacked hash was already reviewed and committed
to the manifest.
The built application's Info.plist also records the pinned core version and
pre-signing upstream binary hash as `MClashMihomoAlphaVersion` and
`MClashMihomoAlphaRawSHA256`.

## Bundled GEO databases

Production builds resolve the current `MetaCubeX/meta-rules-dat` release-branch
revision, download that immutable snapshot, and verify its upstream SHA-256
files before packaging. MClash bundles `geoip.metadb`, `GeoIP.dat`,
`GeoSite.dat`, and `ASN.mmdb`, then seeds missing files into both mihomo's
validation and live core homes. Existing non-empty databases are preserved, so
later user or core updates are never replaced by the app bundle.

## Production release

Public releases are built by the protected GitHub Actions Release workflow.
It runs the test suite, imports the Developer ID certificate into an ephemeral
Keychain, signs with the hardened runtime, notarizes and staples the app and
DMG, signs the Sparkle update, and publishes all assets to GitHub Releases.

Maintainers normally publish by pushing a semantic tag such as `v1.0.0`; the
workflow can also be started manually. No production signing credential is
required on a maintainer's Mac. See [`docs/RELEASING.md`](docs/RELEASING.md)
for the protected environment, required Secrets, build-number policy, and
complete release procedure.

## Safety invariants

- A profile is checked with `mihomo -t` before activation.
- The control API binds only to `127.0.0.1` and uses a random secret retained
  only for the current MClash process lifetime.
- Connection readiness requires live local HTTP and SOCKS5 listeners. When a
  subscription omits them, MClash applies an in-memory mixed-port override
  without rewriting the stored subscription.
- The app owns runtime configuration persistence; API patches are not treated
  as durable state.
- Existing proxy dictionaries are captured before changes; HTTP, HTTPS, SOCKS,
  PAC, auto-discovery, and bypass settings are restored through Apple’s
  `/usr/sbin/networksetup` utility.
- Core updates are delivered with a signed MClash release rather than through
  mihomo's in-place `/upgrade` endpoint.
- Production discovery accepts only the signed bundled core. Developers can
  explicitly opt into fallback discovery with `MCLASH_ALLOW_CORE_OVERRIDE=1`;
  even then, `MCLASH_CORE_PATH` cannot shadow a valid bundled artifact.
