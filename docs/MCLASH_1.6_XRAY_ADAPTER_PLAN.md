# MClash 1.6 Xray integration

MClash 1.6 retains the 1.4 configuration workbench and uses Xray-core for proxy traffic. Sources provide nodes. MClash owns groups, rules, DNS policy, entrances, and workspaces.

## Runtime ownership

Each active workspace runs one Xray process with multiple outbounds. MClash compiles its configuration into Xray listeners, DNS, rules, and balancers. App Routing retains the existing macOS Network Extension and uses private authenticated listeners when it has already selected a group.

The initial per-node process design was rejected after a live prototype. Independent simultaneous groups need independent outbounds, and one Xray process can switch those outbounds without interrupting established streams. MClash does not implement proxy protocol codecs or a replacement transport stack.

| Component | Responsibility |
| --- | --- |
| ConfigurationDocument | Persist sources, nodes, groups, rules, DNS, entrances, and workspaces. |
| XrayConfigurationCompiler | Validate the workspace and produce Xray configuration. |
| ProxyGroupPolicy | Resolve manual selection, ordered fallback, URL latency selection, balance pools, and relay chains. |
| XrayControlSession | Apply routing changes, validate selection receipts, run bounded probes, and persist group state. |
| XrayRuntimeController | Expose runtime status and schedule automatic health checks. |
| CoreSupervisor | Validate candidate configuration and supervise the bundled process. |
| Existing macOS capture | Capture application traffic and relay it to authenticated private listeners. |

The default 1.6 backend is Xray. Existing Mihomo code and resources remain available for legacy compatibility and regression tests. Xray mode does not consume subscription rules, DNS, proxy groups, or controller settings.

## Supported behavior

- Node sources refresh independently of workspace policy. Invalid source imports fail before storage changes.
- Select groups retain explicit choices. Clearing an override returns control to the group policy.
- Fallback groups use member order, failure thresholds, and recovery thresholds.
- URL-test groups use measured latency, a switching cooldown, and absolute and relative tolerance.
- Load-balance groups use healthy node pools and Xray round-robin balancing.
- Relay groups compile ordered node chains through Xray outbound dialers.
- Health settings belong to each group. Probe history is keyed by node connection identity, URL, expected HTTP status, and timeout.
- Public HTTP and SOCKS entrances follow workspace Rule, Global, and Direct modes.
- Rules and capture listeners can change through the existing configuration operations. Invalid candidates restore the previous runtime and durable state.
- Workspace-owned selections survive active source changes.

Unsupported nodes stay visible with a reason and cannot silently fall back to a different backend. The renderer covers VLESS, VMess, Trojan, Shadowsocks, HTTP, HTTPS, SOCKS5, Hysteria2, and WireGuard client outbounds. WireGuard links validate 32-byte keys, addresses, reserved bytes, MTU, and peer routing fields before generating Xray JSON. Each protocol needs both schema validation and a traffic probe before interoperability is claimed. TUIC, unknown plugins, and unsupported transport options are not silently approximated.

Xray does not provide a Mihomo-compatible connection list or API log stream. Those operations report their limitations. Existing captured-flow records and Xray process logs remain separate sources of diagnostics.

## Pinned core

The release uses official Xray 26.9.9 prerelease, source revision `52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120`. The previous stable version lacks the required Unix-domain control API. `Support/xray.env` records the archive and raw binary checksums. Fetch and verification scripts enforce both checksums before signing. The application bundles the upstream license and source notice.

## Delivery stages

1. Establish the backend contract and preserve existing workbench behavior.
2. Pin Xray and prove start, readiness, invalid-candidate handling, and stop.
3. Compile nodes, DNS, entrances, and rules; prove actual routing changes and stream preservation.
4. Integrate group policies, probes, persistence, and health settings into the app and CLI.
5. Freeze source, run acceptance, sign and notarize an immutable `1.6.0-rc.N` prerelease, download it, and verify the artifact.

The user authorized implementation through a test Release. A prerelease can be published from the verified feature branch without merging the stable branch. It must not advance the stable update feed or overwrite the locally installed production app during verification.

## Acceptance gates

- [x] Pinned core archive, binary, source revision, and notices checked.
- [x] Actual supervised process readiness, invalid-config rejection, payload forwarding, and stop checked.
- [x] Actual Xray group selection preserves an established stream and changes the route for new connections.
- [x] Complete app checks for source import, selection, modes, invalid-source rollback, automatic fallback, URL selection, balancing, and relay chains.
- [x] Transactional rule and capture-listener updates checked against the actual core.
- [ ] Group health editing and persisted configuration checked through the app.
- [ ] Protocol interoperability and DNS behavior recorded with explicit limits.
- [ ] Full typecheck, unit tests, integration tests, and release gate pass at the frozen source commit.
- [ ] Signed, notarized prerelease is published, downloaded, and checked.

The checked lifecycle and routing gates are backed by `scripts/smoke-test-xray-supervisor.sh` and `scripts/smoke-test-xray-routing.py`. The workbench acceptance tool is `scripts/smoke-test-xray-app.py`. `ReleaseEvidence/<version>.json` records the final tested source and commands. A passing compile does not establish runtime or Network Extension acceptance.

The first RC supports inline text rule-set entries. Automatic remote rule-set refresh, MRS, DNS-over-TLS, process-name-only rules, and live Fake-IP acceptance remain outside its verified compatibility set. Application identifiers, complete process paths, and user IDs use App Routing. Xray is signed with the stable `mclash-xray` identifier so the signed Network Extension can bypass its own proxy traffic.

## Measurements

The initial single-process routing prototype reached readiness in 41.52 ms and used 33,095,680 bytes RSS. These measurements describe the local prototype, not the finished app. Release evidence must record app-level switching, failure recovery, and resource observations separately.

## Release checks

`scripts/xray-release-preflight.sh` requires a clean worktree, an exact source commit or its evidence-only child, matching core provenance, release notes, and validation commands. A failed or cancelled release tag remains immutable. Fixes use the next RC number.

All local app acceptance uses unique application storage and automation namespaces. It does not modify `/Applications/MClash.app` or the active production Network Extension. Signed-provider activation and public-network endpoint checks must be identified explicitly when they have not been exercised.
