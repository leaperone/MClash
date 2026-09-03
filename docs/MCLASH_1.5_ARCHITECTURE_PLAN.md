# MClash 1.5 architecture and delivery plan

This is the implementation plan for the 1.5.x migration. It is the product
and engineering contract for the native MClash runtime; `docs/MCLASH_PRODUCT_REWORK.md`
keeps the older product-feedback ledger. A checked item means that code and a
matching test or live proof exist. A partial item must not be used as a release
claim.

## 1. Target architecture

MClash owns the configuration, policy, ingress, DNS, routing decision, traffic
inspection and lifecycle. An imported Profile is a node source only. Mihomo is
an interoperability reference and, during the transition, an optional
outbound connector; it is not a source of truth and must not receive policy
sections from an imported Profile.

```text
node-only sources -> normalized node catalog -> MClash compiler
                                                   |
Entrances -> capture -> DNS -> rule engine -> group selection -> connector
             |             |        |                |             |
          HTTP/SOCKS   native DNS  MClash rules   MClash groups   native/legacy
          System Proxy/App Routing/TUN (capabilities)              node transport
```

The final native path must run without a Mihomo process, YAML, controller or
Mihomo listener. A legacy connector may remain behind the same
`OutboundConnector` interface until each protocol has native interoperability
evidence. The fallback is explicit, observable and removable; it may not
silently restore Mihomo control-plane behavior.

## 2. Workstreams and exit criteria

### A. Node-only source import and reconciliation

- [x] Parse source Profiles as node records plus refresh metadata only.
- [x] Drop source `proxy-groups`, `rules`, `rule-providers`, `dns`, `tun`,
      `listeners`, `mixed-port` and controller settings at the import boundary.
- [x] Normalize protocol, endpoint, transport and credential material into a
      stable node fingerprint. Presentation names and rotating credentials do
      not change identity; ambiguous collisions remain visible.
- [x] Persist source ownership and refresh generations so removed nodes cannot
      remain silently selectable and pinned nodes can report why they vanished.
- [x] Prove import/refresh generation Codable compatibility and stable identity
      behavior with fixture tests; the copied-profile shadow run remains a
      separate end-to-end gate below.

Exit criterion: importing or refreshing any source changes only the node
catalog and source metadata; the active MClash policy remains unchanged until a
user/compiler action changes it.

### B. Native control plane and runtime session

- [x] Compile a connector-neutral `CompiledRuntimePlan` from the active
      workspace, including nodes, groups, rules, rule sets, DNS policy,
      entrances and routing mode.
- [x] Validate plan references and listener registry before activation; expose
      workspace revision, listener counts and validation errors in diagnostics.
- [~] `NativeRuntimeEngine` owns a validated plan/listener session, but does
      not yet bind every socket or replace the production default.
- [~] Make `NativeRuntimeEngine` the default lifecycle owner; isolated/test
      AppModel instances now select it by default while production remains
      legacy until the full protocol and lifecycle gates pass. AppModel must
      supply a plan and `MClashListenerRegistry`, never a rendered YAML.
- [~] Remove Mihomo controller readiness, API polling and YAML generation from
      the native activation path. Keep a separately named legacy adapter only
      for rollback during the migration.
- [~] Native listener reload now has atomic replacement, generation guards and
      last-known-good preservation; full engine start/stop/crash recovery is
      still pending.

Exit criterion: a native session can start, reload and stop from a plan with no
Mihomo binary, controller endpoint or YAML file present.

### C. Entrances and capture

All ingress mechanisms are first-class entrance records. They are not rules and
App Routing is not a separate policy editor.

- [x] Registry supports multiple named HTTP and SOCKS5 entrances with unique
      loopback endpoints and explicit enabled state.
- [x] Model System Proxy, App Routing and TUN as entrance capabilities with
      clear capture semantics; do not expose App Routing as a duplicate global
      switch.
- [~] Bind native HTTP CONNECT and SOCKS5 listeners and relay their accepted
      flows through the same route engine. Native listener protocol preambles
      now support SOCKS5, HTTP CONNECT, plain VLESS TCP and Trojan TCP;
      complete AppModel/Network Extension lifecycle wiring and stream edge
      cases remain pending.
- [ ] Add native System Proxy and App Routing lifecycle ownership. TUN remains
      opt-in and must stay disabled unless its Network Extension path is proven.
- [ ] Make arbitrary user-defined ports valid; reserve only ports currently
      occupied by another enabled entrance and report actionable collisions.
- [ ] Show `Entrance -> mode -> matched rule -> group -> node` in connection
      details. Never present an internal recovery port as a user configuration.

Exit criterion: every accepted flow has one identifiable entrance and enters
the same MClash policy pipeline, regardless of whether it came from HTTP,
SOCKS5, System Proxy or App Routing.

### D. Routing modes and built-in targets

- [x] Persist exactly three top-level modes: `Rule`, `Global`, `Direct`.
- [x] Provide stable built-ins: `GLOBAL`/全局出口, `DIRECT`/直连 and
      `REJECT`/拦截. They are selectable targets, not user-created groups.
- [x] In Rule mode evaluate the ordered rule table; Global sends proxy flows
      to the GLOBAL group; Direct returns flows to the native network path.
- [ ] Ensure a direct or rejected decision terminates at MClash and never
      opens a Mihomo relay. Emit the selected mode and disposition in telemetry.
- [ ] Define deterministic behavior for missing/empty GLOBAL and failed group
      selection, with a safe direct/reject policy rather than an implicit core
      default.

### E. Proxy groups and node selection

- [x] Keep a stable `Node Selection` root so rules target one understandable
      place, while regional/failover groups can be nested below it.
- [x] Support criteria-based membership: name/host wildcard or substring,
      source, protocol, tag and endpoint conditions. Refresh recomputes matches.
- [x] Support fixed node pins independently of criteria. Pins use stable node
      fingerprints and show a missing-node warning after refresh.
- [~] Make fallback/relay order explicit and draggable; top-to-bottom is
      priority and is persisted in the workspace.
- [~] Bound large groups, de-duplicate nodes across regional groups by identity,
      and show automatic matches, fixed pins, exclusions and current selection.
      Native source preference now prevents secondary-provider nodes from being
      flattened into ordinary regional groups; explicit group caps and richer
      UI counts remain pending.
- [ ] Replace opaque “new group/import strategy” flows with task templates:
      Node Selection, region priority, failover, fixed node and custom criteria.

Exit criterion: a user can configure hundreds of nodes without toggling every
node, and a source refresh preserves intended membership and priority.

### F. Rules, rule sets and application routing

Rules are a primary product surface, not an Advanced accordion.

- [x] Support exact/suffix/wildcard domains, IP/CIDR and IPv6 CIDR, ports and
      ranges, network conditions, process name/path and application identity.
- [x] Support `GEOIP`, `GEOSITE` (including `gfw`), `RULE-SET`,
      `PROCESS-NAME` and `PROCESS-PATH` with capability-aware validation.
      Reject unsupported matcher names (for example `GEOIP6`) before startup.
- [x] Keep MClash-owned remote rule-set metadata (source, format, behavior,
      path and refresh policy) separate from source Profile providers.
- [x] Add a task-oriented rule editor with plain-language previews and an
      explicit target picker: Node Selection, a named group, DIRECT or REJECT.
- [x] Add App Routing application/process matchers and domain matchers to the
      same rule model; App Routing only supplies the entrance/capture context.
- [ ] Keep deterministic priority/order, cycle detection and a final fallback
      rule. Compile GEO data and rule providers into native matcher inputs.

Exit criterion: every rule can be explained as `match -> action -> connector`
and can be tested without producing a Mihomo YAML document.

### G. Native DNS and outbound protocols

- [x] Model DNS policy in the workspace and pass a connector-neutral bootstrap
      into the native provider. Native DNS does not probe Mihomo.
- [~] Implement split DNS, fake-IP/host policy as supported capabilities, local
      network safeguards and timeout/fallback diagnostics. Local resolver
      safeguards and deterministic native endpoint diagnostics are complete;
      split DNS/fake-IP policy remains pending.
- [x] Maintain protocol descriptors and capability gating for SOCKS5, VLESS,
      Trojan and Hysteria2; an unsupported transport must not be labelled native.
- [~] Native SOCKS5, VLESS/Trojan TCP framing and Hysteria2 session prototypes
      exist; real endpoint interoperability is still required.
- [~] Complete native TCP/UDP connectors (including Shadowsocks and supported
      VLESS WebSocket/Reality variants) with half-close, cancellation, timeout,
      backpressure and credential-redaction tests. Shadowsocks SIP002 TCP
      framing is integrated; UDP/plugins and VLESS WebSocket/Reality remain.
- [ ] Validate at least one real endpoint per supported protocol and record
      handshake, TLS/ALPN/SNI, TCP and UDP evidence. TCP reachability alone is
      not protocol proof.

### H. Traffic monitor and packet-workbench UX

- [x] Separate collection from presentation with `Live`, `Paused snapshot` and
      `Refresh snapshot` states; preserve row selection and scroll position.
- [x] Record stable fields: time, app/process, source/entrance, destination,
      protocol, matched rule, mode, group/chain, node, bytes and state.
- [ ] Add bounded retention/backpressure and an explicit “why this traffic is
      here” inspector, including direct/proxy/reject explanation and DNS path.
- [ ] Add right-click/context actions for exact-domain, suffix-domain, app,
      process, IP/CIDR, GEOIP/GEOSITE and rule-set drafts. Open the normal rule
      editor for review; copying a destination remains secondary.
- [ ] Keep aggregate history separate from volatile rows and label stale data.
      Pausing must freeze visible ordering even while collection continues.

### I. UI, copy and i18n

- [x] Navigation follows the traffic model: Entrances, Configuration/Mode,
      Rules, Rule Sets, Node Groups, Nodes, Sources, then Overview/Diagnostics.
- [x] Remove the standalone “代理” tab and ambiguous “工作方案/新建规则/
      新建代理组” wording. Use task names that describe the result.
- [ ] Apply the Rockxy-inspired calm status header, compact segmented controls,
      stable table/inspector hierarchy and restrained motion. Respect reduced
      motion; live numbers must not make paused work jump.
- [ ] Provide complete Simplified Chinese and English localization for new
      screens, validation errors, protocol capabilities, empty states and
      recovery actions. No user-visible key or fallback English remains.
- [ ] Accessibility pass: keyboard navigation, VoiceOver labels, focus order,
      contrast and actionable error recovery.

## 3. Safety and compatibility rules

- Never overwrite the running production app, profile, system proxy or network
  extension during development. Shadow instances use separate app name,
  application-support directory, lock, automation discovery and random
  loopback ports.
- Never enable TUN or change LAN/private/link-local behavior implicitly. Local
  and private ranges default to DIRECT unless the user explicitly overrides
  the policy; Parsec's required direct destinations remain protected.
- Candidate plans are immutable snapshots. Validate size, references, matcher
  support, listener collisions and protocol capabilities before activation.
  A failed candidate leaves the last-known-good session untouched.
- Redact credentials, subscription URLs and endpoint secrets in logs,
  diagnostics, snapshots and test output. Do not treat a codec/unit test as
  proof of server interoperability.
- Every native fallback to a legacy connector is visible in diagnostics with a
  reason and protocol/transport capability; no hidden Mihomo control-plane
  resurrection is allowed.

## 4. Verification matrix

1. **Static/unit:** typecheck/direct link, model round trips, source policy
   isolation, plan/listener validation, rule ordering/cycles, identity
   reconciliation, DNS framing and connector codecs.
2. **Integration:** compile every routing mode and entrance shape; validate
   GEO/rule-set fixtures, native DNS bootstrap, direct/reject short-circuit,
   HTTP/SOCKS relay and monitor snapshot behavior.
3. **Shadow:** copy the current local Profiles into an isolated namespace,
   use random loopback ports, compile and inspect the native plan and
   connector matrix. Full native session traffic/connection trace comparison
   remains pending; do not touch the production app or System Proxy.
4. **Protocol:** run real endpoint tests for every connector claimed as native;
   cover TLS/ALPN/SNI, authentication, TCP, UDP, cancellation and failure
   recovery. Record endpoint, timestamp, commit and redacted result.
5. **Live CLI:** inspect active workspace/source/entrance/mode, list listeners,
   test direct/proxy/reject, inspect a frozen traffic row, and verify that a
   missing/invalid candidate does not replace the running session.

## 5. 1.5.x release gates and sequence

### Minor release: 1.5.0

- [ ] All required workstreams above are complete or explicitly excluded from
      the supported 1.5 contract; no unchecked item is presented as native.
- [ ] Mihomo is absent from the default control/data path, or the release notes
      clearly identify the remaining connector-only compatibility boundary.
- [ ] Clean checkout build succeeds on the standard free `macos-26` runner.
      Do not use `macos-26-xlarge`, `macos-15-xlarge` or other larger runners.
- [ ] Full static/unit/integration/shadow/protocol/CLI evidence is attached to
      the release candidate. Package, sign, notarize and inspect the DMG/ZIP.
- [ ] Install only the isolated 1.5.0 build first; preserve a backup and a
      documented rollback path. Production installation requires explicit
      acceptance after the isolated CLI run.

### Patch release: 1.5.1 (or the next fix-forward patch)

- [ ] Start from the exact released 1.5.0 commit/tag; never reuse or mutate a
      failed immutable tag.
- [ ] Fix only verified regressions from 1.5.0 acceptance, with a regression
      test and release-note entry for each fix.
- [ ] Repeat clean build, signing/notarization, package hash, shadow and CLI
      acceptance on standard `macos-26`.
- [ ] Install the patch into the isolated test namespace, then perform the
      separately authorized production upgrade and verify rollback readiness.

## 6. Progress record (2026-09-03)

- `e7c7035` persists per-source refresh generations on nodes, keeps legacy
  manifests decodable, and covers credential rotation without changing node
  identity.
- `7c4749e` keeps native and legacy backends consistent across the profile
  fleet, preventing an auxiliary session from silently launching Mihomo when
  native runtime is selected.
- `574e438` and `44e5b03` make native listener replacement transactional and
  serialize reconfiguration; delayed callbacks from an older generation are
  ignored. A focused invalid-reload test preserves the running listener.
- Root verification after these changes: `typecheck.sh`, integration smoke,
  and `test-release-preflight.sh` all pass. The local CommandLineTools Swift
  Testing runtime still aborts during the direct shared-test binary; this is
  tracked as a toolchain limitation and is not counted as protocol evidence.
- The isolated native CLI smoke initially exited with signal 137 because a
  second bundle reused the production bundle identifier while
  `LSMultipleInstancesProhibited` was active. `7903abc` stages a disposable
  bundle with a unique identifier and ad-hoc signature; the smoke now
  publishes a real native automation endpoint without touching production.
- `dd8be34` adds task-oriented rule shortcuts for Application, Domain and GFW
  List matching, plus an explicit explanation of Direct, Reject and group
  targets in the editor.
- `64cf246` makes native DNS upstream selection deterministic and keeps
  multicast/unspecified resolver addresses on the local network path; focused
  DNS shared and Network Extension tests cover both safeguards.
- `93750dd` makes isolated/test instances select the native runtime by default;
  production keeps the legacy adapter unless explicitly migrated, and
  `MCLASH_LEGACY_RUNTIME=1` is an explicit rollback switch.
- `4014746` adds application-level quick actions to the traffic inspector
  alongside existing process-path and domain rule drafts.
- `1484e41` prevents native workspace activation and rollback from invoking
  the legacy runtime override coordinator; native activation now keeps the
  compiled plan in-process without materializing Mihomo YAML.
- `59e19e4` resolves native proxy groups through explicit pins, dynamic
  selectors, nested groups and node health/availability, with cycle and empty
  group fail-closed behavior; `4dd97b2` stabilizes paused traffic snapshot
  ordering and selection while the controller refreshes.
- `38d97fa` extends the native inbound catalog connector beyond SOCKS5 to
  validated HTTP CONNECT plus plain VLESS/Trojan TCP handshakes; unsupported
  transports remain fail-closed.
- `59e19e4` and `4dd97b2` are included in the clean verification run after
  resolver/snapshot integration; native group target selection now follows
  selector and health policy instead of the first raw member.
- `38d97fa` is included in the clean verification run and routes native
  inbound HTTP/SOCKS traffic through protocol-specific outbound handshakes
  for SOCKS5, HTTP CONNECT, plain VLESS TCP and Trojan TCP.
- `b431f54` integrates stateful native Shadowsocks SIP002 TCP stream plans;
  salt/nonce framing is retained across application writes and unsupported
  plugins/UoT remain explicit fallback cases.
- `16ee6f6` keeps CLI smoke startup lightweight with an explicit
  `MCLASH_SKIP_AUTO_CONNECT=1`, so endpoint diagnostics can be verified before
  any large source catalog is connected.
- Latest isolated smoke output confirms `backend=native`, capabilities
  `nativeRuntime/nativeRouting/nativeDNS`, `controlPlaneAvailable=false`, and
  `hasCompiledRuntimePlan=true`; production processes and sockets were not
  changed.
- `b431f54` is covered by the clean typecheck and its factory tests preserve a
  single stateful Shadowsocks codec for target, payload and response frames.
- The current built bundle passes `smoke-test-native-runtime-cli.sh` after
  disposable-bundle staging, proving the native diagnostics endpoint can be
  queried without auto-connecting a source or reusing the production bundle
  identity.
- The same smoke script now accepts `MCLASH_SHADOW_SOURCE_ROOT` and validates
  that a copied tree produces a compiled workspace plan. The first run against
  the current production tree exposed `hasCompiledRuntimePlan=false` and
  `workspaceRevision=null`; this is recorded as a real shadow-import blocker,
  not treated as a successful copied-profile acceptance.
- The shadow script now copies only authoritative `Configuration` and
  `Profiles`, normalizes copied entrance binds to loopback, and excludes stale
  runtime/settings state. A subsequent run against the current local tree
  passed with `hasCompiledRuntimePlan=true`, `workspaceRevision=28`, five
  entrances and a non-empty connector capability matrix; Hysteria2 remained
  explicitly `legacyFallback` with its QUIC reason.
- With `MCLASH_SHADOW_AUTO_CONNECT=1`, the copied-profile shadow also retains
  only `State/active-profile.json` and reached the in-process native runtime
  `running` state with `startedAt` set and four enabled listener handles
  running. The Network Extension and System Proxy remain inert, so this proves
  lifecycle/plan activation but not external traffic interoperability.
- The rebuilt bundle was rerun against the current local tree after the
  native payload boundary change and again reached `state=running` with
  `startedAt`, `workspaceRevision=28`, four running listener handles and
  `controlPlaneAvailable=false`.
- After the YAML-free native compiler change, a fresh rebuilt bundle again
  passed copied-profile shadow auto-connect: `state=running`,
  `hasCompiledRuntimePlan=true`, `workspaceRevision=28`, and four running
  listener handles, with no native startup error.
- After enabling CUNOE-Proxy source preference, the rebuilt current-profile
  shadow again reached `state=running` with the same five listener handles;
  capability diagnostics remained explicit, including Hysteria2's QUIC
  `legacyFallback` reason.
- The subsequent full integration smoke after native payload changes passed
  GEO verification, dual-profile/listener/crash-recovery checks, system proxy
  read-only checks and API smoke; no production service was restarted.
- `b84a176` adds the isolated native CLI smoke to the signed release job on the
  standard `macos-26` runner, so every future release package must publish a
  verified native automation endpoint before GitHub Release publication.
- `0be3930` adds a real loopback HTTP entrance test: MClash accepts a client
  CONNECT only after the native HTTP upstream returns 200, then bridges
  `ping`/`pong` payloads in both directions.
- `6486703` removes legacy Mihomo route-catalog and private SOCKS fields from
  Network Extension payloads when native inbound plus native DNS are active;
  only the connector-neutral node catalog, listener registry and native DNS
  bootstrap remain, with a regression test for the boundary.
- `57db0ac` stops constructing a Mihomo UDP association probe during native
  DNS startup; the legacy probe is now created only by the compatibility DNS
  path.
- `dbc192e` skips constructing the legacy `RuntimeOverrideActivationCoordinator`
  and override store in native/test instances, preventing stale YAML override
  state from participating in native startup; production legacy initialization
  remains unchanged.
- `94f4d0d` makes `AppModel.compileConfiguration()` request a connector-neutral
  plan with no Mihomo YAML when native runtime is selected; a regression test
  verifies the compatibility payload is empty while plan validation succeeds.
- `be14dd3` keeps the same payload boundary when DNS capture is disabled in a
  native workspace, so legacy route material is not reintroduced by an opt-out.
- `c2071c3` adds a bounded real UDP loopback test for `SocketDNSUpstream`:
  a local server receives the query, preserves the transaction ID and returns
  a validated DNS response without external network access.
- `37a7105` fixes native flow planning to derive the destination directly from
  the intercepted endpoint instead of requiring a legacy Mihomo route plan;
  VLESS, Trojan and Shadowsocks native connectors now receive their proper
  destination and cannot be misclassified as SOCKS5 handshakes.
- `2230554` aligns the connector capability matrix with the native Shadowsocks
  validator by rejecting empty passwords as `legacyFallback`, with a focused
  regression test.
- The standalone capability-matrix binary now executes 4/4 tests on this Mac,
  covering stable route ordering, VLESS WebSocket/Reality classification,
  empty Shadowsocks password fallback and Codable round-trip.
- `aa20886` adds native source preference: regional/generic groups select
  CUNOE-Proxy nodes when that source exists, while explicitly named AI,
  飞鸟云 or kaze groups may opt into secondary sources. Nested groups apply
  the policy independently, preventing unrelated AWS nodes from flattening
  into every regional group.
- The latest direct application test binary executes the CUNOE resolver suite
  and reports `500 tests in 72 suites passed` before the known
  CommandLineTools shared-test runtime abort; the resolver tests themselves
  pass.
- `db92b4a` adds admission coverage for native inbound HTTP, VLESS TCP and
  Trojan targets; protocol-specific handshake tests remain part of the real
  endpoint/interoperability gate.
- `883535a` extends the MClash-owned inbound connector to VLESS WebSocket:
  HTTP Upgrade is validated with RFC 6455 accept checks before the masked
  VLESS binary request is sent; loopback endpoint interoperability is still a
  separate release gate.
- The rebuilt bundle and latest isolated CLI smoke pass after the WebSocket
  integration; diagnostics continue to report `controlPlaneAvailable=false`
  and a compiled native plan without starting a Mihomo process.

### Definition of done

The migration is complete only when a fresh node-only import, native plan,
native entrance, native DNS, native rule/group decision, supported native
connector, monitor snapshot and CLI inspection all work in an isolated app;
the production app remains untouched until that evidence is reviewed; and the
1.5.0 and subsequent patch artifacts are published from verified commits.
