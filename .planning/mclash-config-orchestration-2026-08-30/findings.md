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

## Remaining gates before release

- Run the final focused and full direct test suites after the last edits.
- Add/verify explicit UI localization keys for the new workbench copy.
- Complete a second review of runtime compiler/Network Extension behavior and perform app-level smoke validation.
- Update release notes/version, build the signed app through the repository release workflow, and verify exact tag/SHA, artifacts, appcast, checksums and installation/runtime acceptance.
