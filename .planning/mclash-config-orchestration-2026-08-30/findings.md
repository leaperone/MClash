# Findings

## 2026-08-30 baseline

- `origin/main` was refreshed from `9245367` to `a2fd9e7`; the latest main already contains the 1.3.7 information-architecture/accessibility simplification.
- The root checkout had only the untracked task planning directory; work continues on `feature/mclash-config-orchestration` so the user-owned planning files remain intact.
- Existing `ProfileStore` persists opaque full YAML and `RuntimeConfigurationComposer` patches source YAML. This is incompatible with node-only imports and requires the new blank-document compiler for unified mode.
- Existing App Routing has a versioned independent JSON snapshot and Automation commands. The UI is being reduced to a capability switch, while old API compatibility remains in place during migration.
- Existing UI already provides NavigationSplitView, list/table surfaces and connection Inspector behavior. The new Configuration workbench reuses this native vocabulary and adds strategy-owned Sources/Nodes/Proxy Groups/Rules/Workspaces surfaces.

## Implemented in this round

- Added strategy-owned configuration models, deterministic reference diagnostics and stable Node fingerprints.
- Added node-only source importer with duplicate detection, ignored strategy-section diagnostics and source refresh merge behavior.
- Added atomic JSON ConfigurationStore with invalid-document quarantine and private storage directories.
- Added deterministic MClash-to-Mihomo compiler and one-way Network Extension capture adapter.
- Added compiled configuration activation path and a unified-configuration toggle boundary in AppModel.
- Added Configuration workbench UI with responsive Sidebar/List/Inspector, source import, group/rule/workspace creation and workspace activation actions.
- Removed App Routing from the primary navigation surface; its status remains reachable through the capability switch and Traffic evidence.
- Extended backups to include the authoritative Configuration directory while preserving compatibility with older backup manifests.

## Review-driven corrections

- Reviewed and fixed compiler handling for nested flow-map/list node parameters, rule-set output, workspace membership diagnostics, entrance ports/bind addresses, DNS fields and matcher CSV safety.
- Fixed App Routing unified-mode toggle to update the Workspace entrance and roll back the strategy document if activation fails.
- Fixed backup optional-component restore behavior and disabled hidden-entry skipping in symbolic-link validation.
- Fixed UI navigation wiring so Proxy Groups and Rules point to the new authoritative workbench instead of the legacy Mihomo projections.
- Fixed literal interpolation errors in synchronization, rollback and quarantine diagnostics.

## 2026-08-30 follow-up review and corrections

- App Routing was confirmed as an entrance capability, not a navigation/resource type. The visible control is the Application traffic switch in Entrances; old deep links are normalized to Entrances and Node Groups for compatibility.
- Rules remain a first-level configuration destination and use the unified matcher editor for application, process, user, domain, IP/CIDR, transport and port conditions.
- Node Group membership no longer requires hundreds of toggles: automatic selectors and fixed pins are persisted separately, with deterministic refresh-time resolution.
- A refresh with unsupported or incomplete node entries is now non-authoritative and cannot mark all prior nodes source-removed. A source file read failure is isolated to that source so healthy sources continue synchronizing.
- Source synchronization diagnostics are merged by stable diagnostic ID to avoid duplicate warnings in the source inspector and Attention surface.
- Top-level ignored-section detection now considers only zero-indent YAML keys, preventing nested node parameters named `dns`/`tun` from being misclassified.
- Imported `tag`/`tags` and `region`/`country` are retained as grouping metadata while excluded from endpoint identity, so provider presentation changes do not create a new pinned node.
- The workbench uses a compact inspector sheet below the readable list width, flexible filter controls, and localized filter/search/default selector copy.
- Because Mihomo exposes one managed HTTP, SOCKS5, TUN and App Routing listener per runtime, validation now rejects multiple enabled entrances of the same kind instead of silently ignoring the extra listener.
- Ordinary source details redact subscription query/userinfo/path data to a host-only label; node fingerprints and diagnostics remain credential-safe hashes/messages.

## Remaining gates before release

- [x] Run the final focused and full direct test suites after the last edits.
- [x] Add/verify explicit UI localization keys for the new workbench copy.
- [x] Complete final typecheck/direct tests/integration smoke and app-level smoke validation; no real-window acceptance has been performed in this CLI environment.
- Update release notes/version, build the signed app through the repository release workflow, and verify exact tag/SHA, artifacts, appcast, checksums and installation/runtime acceptance.

## Release gate result

- [x] Release notes/version, signed build, notarization, appcast/deltas, checksums and public GitHub Release verified for `v1.4.5` (Actions run `33306910186`).
- [ ] Real interactive window acceptance remains a separate manual macOS gate; it was not claimed from CLI or CI evidence.
