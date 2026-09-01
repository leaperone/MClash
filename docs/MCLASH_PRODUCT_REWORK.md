# MClash product rework task

This is the single source of truth for the rework requested after the 1.4.11
migration. It tracks product behavior, not only visual polish. Imported Profile
YAML remains a node source; the MClash workspace owns policy and runtime output.

## Product contract

1. A source contributes node connection data and refresh metadata only.
2. MClash owns routing mode, rules, rule sets, proxy groups, DNS, TUN and
   local entrances. Source `proxy-groups`, `rules`, `rule-providers`, `dns`,
   `tun`, controller and listener settings are never copied into the active
   MClash runtime.
3. The normal route is `entrance -> routing mode -> rule/default policy ->
   Node Selection -> strategy group -> node`.
4. A user can inspect a stable traffic snapshot, select a row, and turn an
   observed domain into a reviewed MClash rule without leaving the monitor.
5. Every generated runtime is validated by the bundled Mihomo before it can be
   activated; a failed candidate never replaces the last known-good runtime.

## Workstreams and acceptance gates

### A. Configuration truth and terminology

- [x] Keep source strategy sections out of node import and generated runtime.
- [x] Show the active MClash workspace separately from the source Profile.
- [x] Replace “Profile” in connection details with “Source” where it means
      imported data, and show `Workspace`, `Source`, `Runtime` and `Entrance`
      as separate fields.
- [x] Remove ambiguous “workspace/work方案/代理” copy from primary flows;
      use “配置”, “入口”, “策略组”, “规则” consistently.

### B. Routing modes and predefined policies

- [x] Persist an explicit workspace routing mode: `Rule`, `Global`, or
      `Direct`.
- [x] Provide stable built-in placeholders: `GLOBAL`/“全局出口” (select),
      `DIRECT`/“直连” and `REJECT`/“拦截”; users can choose them without
      creating a rule first.
- [x] Compile `Rule` as the rule table, `Global` as the GLOBAL group, and
      `Direct` as DIRECT, with a visible mode switch in the overview and
      configuration header.
- [x] Keep the MClash-owned `Node Selection` group as the stable default for
      rule actions; regional and failover groups remain nested choices.

### C. Entrances

- [x] Treat HTTP, SOCKS5, App Routing and TUN as entrance records, not routing
      rules. App Routing is a capture switch/entrance only.
- [x] Support multiple HTTP/SOCKS5 records using Mihomo `listeners` (or an
      explicitly isolated core session where a listener cannot express the
      requested semantics); never silently keep only the first record.
- [x] Preserve each HTTP/SOCKS5 entrance's own `DIRECT`, `REJECT`, or
      strategy-group target in Rule mode. Global and Direct modes explicitly
      override listener targets with `GLOBAL` and `DIRECT`.
- [x] Give every entrance a name, bind address, port and active-configuration
      target, with clear collision diagnostics. Unsupported per-entrance
      workspace overrides are rejected explicitly rather than silently merged.
- [x] Show the actual active entrance in overview/connection details; do not
      present a generic `40808` as if it were a separate policy.

### D. Strategy groups

- [x] Dynamic selectors support wildcard-like name/host matching and source,
      protocol and tag conditions.
- [x] Fixed pins are independent from selectors and large lists are bounded.
- [x] Edit group members in order; for fallback/relay-like policies, top to
      bottom is the explicit priority and supports drag/reorder.
- [x] Show a compact group explanation in the list: automatic match count,
      fixed count, nested strategy order and current selection.
- [x] Replace “Add common strategy groups” with an understandable template
      action that says exactly what it adds and which rules it redirects.

### E. Rules and rule sets

- [x] Make Rules a first-class primary destination, not an advanced appendix.
- [x] Support domain exact/suffix/wildcard, IP/CIDR, port/range, network,
      application/process and user conditions in one editor.
- [x] Add Mihomo `GEOIP`, `GEOSITE` (including `gfw`) and IPv6
      `IP-CIDR6`. The bundled core rejects the non-existent `GEOIP6` type.
      `RULE-SET`, `PROCESS-NAME` and `PROCESS-PATH` representations with
      validation and readable previews.
- [x] Model remote rule providers with behavior/format/path/source metadata;
      never re-import a source Profile’s provider as executable policy.
- [x] Make rule action default to `Node Selection`, and expose mode/default
      behavior without requiring an opaque “new rule” workflow.

### F. Traffic monitor / packet-workbench interaction

- [x] Decouple collection from presentation. Live collection continues in the
      background, while the table has explicit `Live`, `Paused snapshot`, and
      `Refresh snapshot` states.
- [x] Preserve selected row and scroll context when new samples arrive; avoid
      reordering a paused table.
- [x] Add stable columns for time, process/app, destination, protocol, route,
      rule, bytes and state; make the inspector explain source/workspace/entry.
- [x] Add row context actions: copy destination, close connection, create
      exact-domain rule, create suffix rule, add app/process condition.
- [x] Open the normal rule editor with a reviewed draft; do not save a rule
      directly from a context menu.
- [x] Keep aggregate history separate from volatile live rows and label stale
      data explicitly.
- [x] Cancel in-flight presentation work when a snapshot is paused, so a
      frozen table cannot jump after the user starts inspecting it.

### G. Overview and visual system

- [x] Make the overview status card answer: connected to which workspace, via
      which entrance, in which mode, and through which current strategy.
- [x] Replace implementation labels (“Profile Mixed”, raw runtime port) with
      human labels plus a secondary copyable endpoint.
- [x] Use Rockxy-inspired hierarchy (calm status header, compact segmented
      workspaces, stable table/inspector) while retaining native macOS controls.
- [x] Respect reduced motion and avoid animating values/rows unless the user
      explicitly chooses Live mode.

## Verification matrix

- Unit/model tests for mode persistence, built-in policy identities, ordered
  group members, rule-set types, snapshot freeze/resume and rule drafts.
- Real bundled Mihomo `-t` for every generated mode and entrance shape.
- Shadow run using copied local Profiles, random loopback ports and bundled GEO
  data; never start a second full MClash or touch the system proxy.
- Read-only live acceptance: controller state, active workspace/source, runtime
  header/counts, listener ownership, and no source strategy leakage.
- Release gate only after all above pass; installing/upgrading the user’s active
  app is a separate explicit action.

## Current status

The 1.4.11 runtime is unified and live on this Mac. The implementation slice in
the working tree covers the product contract above. Local and remote release
verification is complete through `v1.4.13`; installation acceptance remains a
separate explicit action. The bundled Alpha core rejects the non-existent
`GEOIP6` matcher; IPv6 country-style routing must use `IP-CIDR6` or supported
`GEOIP`/`GEOSITE` rules. TUN remains explicitly unsupported by this macOS build,
and App Routing remains one system capture capability even though HTTP/SOCKS5
entrances support multiple named listeners.

## Implementation ledger (2026-09-01)

- [x] Node-only import and source refresh reconciliation: stable IDs are derived
      from normalized protocol/host/port/transport material; rotating
      credentials and presentation labels do not orphan pins. Ambiguous
      credential collisions stay visible instead of silently swapping nodes.
- [x] Runtime compiler starts from a blank document and emits only the active
      MClash policy. Source `proxy-groups`, `rules`, `rule-providers`, DNS,
      TUN, listeners and controller settings are not copied.
- [x] Rule/Global/Direct mode persistence and controller switching, including a
      generated `GLOBAL` selector and safe fallback validation.
- [x] Named, collision-checked HTTP/SOCKS5 listeners through Mihomo
      `listeners`; App Routing is shown as one entrance switch.
- [x] Node Selection hierarchy preset with US/JP/HK, automatic, manual,
      failover, residential and direct children; selectors update after source
      refresh, pins remain explicit, and nested/fixed order has move controls.
- [x] First-class Rules surface with app/process/domain/IP/port/network,
      `GEOIP`, `GEOSITE` (including `gfw`), `PROCESS-NAME`, `PROCESS-PATH`, and
      IPv6 `IP-CIDR6` output. Unsupported `GEOIP6` is rejected before startup.
- [x] MClash-owned Rule Sets with explicit behavior/format/path/source metadata;
      source providers are never auto-enabled.
- [x] Traffic workbench live/frozen snapshots, manual refresh, stable selection,
      inspector context, and reviewed quick-rule drafts from live/history/app
      rows.
- [x] Overview and menu-bar copy now identify configuration, workspace, node
      source, entrance and runtime separately; a read-only macOS proxy probe
      warns when an external 127.0.0.1 proxy remains enabled.
- [x] Hide the internal Mixed recovery socket from the user entrance list and
      prefer named HTTP/SOCKS listeners for system-proxy endpoints; expose the
      recovery port only while it is actually needed for fallback.
- [x] Keep unified compiled listeners during App Routing hot reloads; legacy
      source sanitization no longer deletes MClash-owned HTTP/SOCKS entrances.
- [x] Replace ambiguous generic add controls with explicit labels and expose
      selector priority up/down controls for fallback groups.
- [x] Correct Rule Set target/parameter ordering (`TARGET` before `no-resolve`
      or `src`) and validate explicit policy targets before activation.
- [x] Verification completed so far: typecheck/direct link, full direct test
      suite, integration smoke, and copied-profile shadow run with random
      loopback ports. No test starts a second MClash app or changes the system
      proxy.

### Release gates still to execute

- [x] Re-run typecheck, the complete direct test suite, and the integration
      smoke suite against the final working tree. Bundled Alpha `-t` and actual
      HTTP/SOCKS I/O passed for the copied current manifest.
- [x] Perform read-only live acceptance against the currently running
      downgraded 1.3.7 app; production PIDs, controller, listeners and system
      extension state were unchanged.
- [x] Re-run the complete release build from a clean commit and inspect the
      packaged generated runtime with the bundled Alpha core.
- [x] Prepare and verify the next patch artifact (`v1.4.13`), then keep
      installation separate from publication.

### Release verification record

- `v1.4.12` tag/run is intentionally retained as a failed, immutable attempt:
  its code verification passed, but the shared runner's unauthenticated
  MetaCubeX GEO request hit GitHub REST rate limit (`403`). It was not
  published and was not reused.
- `v1.4.13` was published from commit `95c79f3` after passing the authenticated
  GEO verification fix. GitHub Actions run `33451368492` completed all verify,
  signing, notarization, packaging, and publication jobs successfully.
- Published artifact checks were repeated from the release: DMG and ZIP
  hashes match `SHA256SUMS`; the ZIP bundle is accepted by `spctl` as
  `Notarized Developer ID`, and its bundled Alpha core/GeoData pass local
  verification. The next release gate is installation acceptance, which is
  intentionally separate and still requires explicit user authorization.

## Follow-up feedback backlog (2026-09-01)

The following items are now part of the same product task and must be closed
before the next patch is considered complete:

- [x] Make navigation follow the traffic model: Entrances first, then
      Configuration/Mode, Rules and Rule Sets, Node Groups, Nodes, and Sources.
      Keep Overview as status, not as the first configuration step.
- [x] Represent macOS System Proxy and App Routing as entrance capabilities;
      remove standalone duplicate tabs/switches and explain capture semantics
      in the Entrances surface.
- [x] Scope active node groups to the selected CUNOE-Proxy source unless the
      user explicitly opts into another source. Regional groups must not
      flatten unrelated regions or duplicate nodes across US/JP/HK groups.
- [x] Repair stale managed Mixed-port collisions and runtimes where mihomo
      reports `mixed-port: 0`; a node-only source must never be treated as a
      missing Mixed configuration.
- [x] Put China routing safeguards (`GEOSITE,cn` and `GEOIP,CN`) before the
      proxy catch-all, and expose matched rule, payload, process, bytes and
      chain in the traffic inspector.
- [x] Make Traffic a packet-workbench with explicit Live/Paused/Refresh
      snapshots and primary context actions for exact/suffix domain, app,
      process, IP/CIDR, GEOIP/GEOSITE and rule-set entries; keep Copy secondary.
- [ ] Replace opaque “new rule/group/workspace” flows with task-oriented
      templates and selector criteria, including visible fallback priority.
- [x] Provide an isolated test-app namespace (data, lock, automation discovery
      and loopback ports) so new builds can be exercised without replacing the
      user's running MClash or Network Extension.
