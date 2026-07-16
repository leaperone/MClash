# MClash

MClash is a native macOS controller for the
[MetaCubeX mihomo Alpha](https://github.com/MetaCubeX/mihomo/tree/Alpha) core.
The application is written with SwiftUI and AppKit. The Go core remains an
isolated process and is controlled through its authenticated loopback REST and
WebSocket API.

## Current scope

- Native window and dedicated menu bar quick-control popup
- Alpha core discovery, configuration validation, lifecycle supervision, and
  bounded crash recovery
- Keychain-backed local controller secret
- Local and remote profile storage with transactional activation and rollback
- Rule / Global / Direct routing, policy groups, searchable node selection, and
  latency testing
- Rules, proxy providers, rule providers, live connections, logs, and traffic
- REST/WebSocket API models, authenticated client, and stream reconnection
- Lossless macOS system proxy snapshot, activation, persistence, and restore

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
it in the application. End users never select or download a core.

## Bundled mihomo Alpha artifact

MClash currently pins `alpha-a70af27` from the upstream `Prerelease-Alpha`
channel. Release metadata lives in `Support/mihomo-alpha.env`; SHA-256 values for
the unpacked, executable artifacts live in `Support/mihomo-alpha.sha256`.

Both Apple Silicon and Intel use the same artifact-selection code. The first
release target is Apple Silicon; every supported architecture must have a
separately reviewed raw hash in the manifest before its core can be fetched.
The current Apple Silicon artifact is verified before every application build
and integration run:

```sh
./scripts/verify-mihomo-alpha.sh
./scripts/verify-mihomo-alpha.sh --architecture x86_64
```

The second command intentionally fails until an independently reviewed Intel
hash and artifact are added in a dedicated release change.

`fetch-mihomo-alpha.sh` fetches the pinned version rather than following the
moving `version.txt`, verifies the selected archive against upstream
`checksums.txt`, and refuses to download or replace an artifact unless its
unpacked hash was already reviewed and committed to the manifest.
The built application's Info.plist also records the pinned core version and
pre-signing upstream binary hash as `MClashMihomoAlphaVersion` and
`MClashMihomoAlphaRawSHA256`.

## Production release

`build-app.sh` creates an ad-hoc signed local build by default. A distributable
release requires a Developer ID Application certificate and Apple notarization:

```sh
export MCLASH_VERSION=1.0.0
export MCLASH_BUILD_NUMBER=100
export CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)'
export NOTARYTOOL_PROFILE='mclash-notary'
./scripts/release-app.sh
```

The release script enables the hardened runtime, verifies the signature,
submits the app to Apple, staples the ticket, performs Gatekeeper assessment,
and writes a SHA-256 alongside the final zip. Signing credentials are never
stored in this repository.

## Safety invariants

- A profile is checked with `mihomo -t` before activation.
- The control API binds only to `127.0.0.1` and uses a random secret stored in
  Keychain.
- The app owns runtime configuration persistence; API patches are not treated
  as durable state.
- Existing system proxy dictionaries are captured and restored exactly.
- Core updates are delivered with a signed MClash release rather than through
  mihomo's in-place `/upgrade` endpoint.
- Production discovery accepts only the signed bundled core. Developers can
  explicitly opt into fallback discovery with `MCLASH_ALLOW_CORE_OVERRIDE=1`;
  even then, `MCLASH_CORE_PATH` cannot shadow a valid bundled artifact.
