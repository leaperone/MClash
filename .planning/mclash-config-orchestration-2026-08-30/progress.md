# Progress

## Status

- [x] Refresh `origin/main` and create isolated implementation branch.
- [x] Add Phase 1 authoritative configuration models and validation.
- [x] Add Source/node-only importer, stable identity merge and private ConfigurationStore.
- [x] Add deterministic Mihomo compiler, capture adapter and compiled activation seam.
- [x] Add Rockxy-style native Sidebar/List/Inspector workbench UI and new navigation destinations.
- [x] Remove App Routing as a primary rule-management surface; retain capability switch and Traffic evidence.
- [x] Run direct typecheck and full direct tests after review corrections.
- [x] Complete two independent model/UI reviews and fix reported P1/P2 issues.
- [x] Complete localization and final UI/runtime static review.
- [x] Build, sign, publish and verify the prior `v1.4.1` release.
- [x] Move App Routing into the Entrances page as one application-traffic switch; remove the visible Proxy/App Routing destinations and legacy menu actions.
- [x] Add editable HTTP/SOCKS5/TUN entrance creation with type, port, bind address and default action.
- [x] Protect source refreshes from partial/unsupported parses, preserve nodes on read failure, and de-duplicate synchronization diagnostics.
- [x] Make the workbench inspector adaptive at compact widths and keep filter/search copy localized.
- [x] Re-run final typecheck, direct tests and integration smoke for this follow-up.
- [ ] Perform real-window macOS acceptance in a manual macOS session (not available in this CLI session).
- [x] Publish `v1.4.5` from the verified commit and confirm the public assets/checksums.

## Verification evidence

- `git fetch --prune origin main`: remote advanced to `a2fd9e7da8fb3e6731467cc3c8d08a8f5acdc4e4`.
- `git merge --ff-only origin/main`: local main fast-forwarded cleanly; task planning history was preserved.
- `./scripts/typecheck.sh`: passed after the final model, runtime, and UI edits.
- `./scripts/test-direct.sh`: exit code 0 after the follow-up edits; 417 MClash tests in 60 suites, 114 Network Shared tests, 29 Network Extension tests, 5 Automation tests and release-script tests passed.
- `git diff --check`: passed after the final edits.
- GitHub PR #31 merged implementation into `origin/main` at `e70f165`.
- The first `v1.4.0` release workflow found one incomplete new-test expectation; immutable tag was left untouched.
- Fix-forward PR #33 merged at `7d2a50e`; `v1.4.1` release tag points to `f8998dd` and workflow `33270416958` completed successfully.
- `v1.4.1` published DMG/ZIP, two verified Sparkle deltas, appcast, corresponding mihomo source, Sparkle license and SHA256SUMS; downloaded assets all matched checksums and the ZIP app passed local deep codesign verification.

## 2026-08-30 follow-up evidence

- Sidebar now exposes Configuration, Rules, Nodes, Sources, Entrances, DNS and Node Groups; `.proxies`/`.appRouting` remain enum/deep-link compatibility cases only and normalize to the new destinations.
- Entrances renders the application-traffic switch once and filters the App Routing capability out of the editable entrance list.
- Node Groups accept selector conditions and fixed pins; selector membership is resolved against the current enabled catalog during compilation.
- Source refresh removal is gated by `refreshAuthoritative`; incomplete/unsupported parses and per-source read failures keep prior source links and node health.
- Unified refreshes recompile the current MClash document after source synchronization; failed recompilation is surfaced as an actionable configuration diagnostic while the last known-good compiled snapshot remains available for recovery.
- Applying the unified configuration can now select the first stored source profile when no legacy profile is active, so a fresh source import is not blocked by an empty active-profile slot.

## Final local verification for this follow-up

- `./scripts/typecheck.sh`: passed; direct MClash, CLI and Network Extension links succeeded.
- `./scripts/test-direct.sh`: passed; MClash, Network Shared, Network Extension, Automation and release-script suites all passed, including source-refresh degradation/read-failure coverage.
- `./scripts/integration-test.sh`: passed; mihomo core supervisor, dual-profile AppModel, HTTP/SOCKS/runtime-listener, crash-recovery, system-proxy read and controller API smoke scenarios passed.
- `git diff --check` and all eight `Localizable.strings` `plutil -lint` checks passed.
- No signed app/package or real interactive window acceptance was performed in this CLI session; a new release remains intentionally out of scope until that gate is run.

## Published release evidence

- Tag `v1.4.5` and `origin/main` point to `4fa9621fe849d7c0258801395d38f290d0d0bc1a` (annotated tag object peels to that commit).
- GitHub Actions Release run `33306910186` / run number `58` completed successfully: verify `22m48s`, sign/notarize/publish `7m50s`.
- Public release: https://github.com/leaperone/MClash/releases/tag/v1.4.5 (non-draft, non-prerelease, latest).
- Eight published assets downloaded successfully; every entry in `SHA256SUMS` verified, and the downloaded ZIP app passed deep strict codesign verification with version `1.4.5`, build `58`.
