# Releasing MClash

Production releases are built entirely on GitHub Actions. A maintainer does not need to install a signing certificate, Xcode, or notarization credentials locally.

## One-time repository setup

Create a protected GitHub Environment named `release`. Restrict deployment branches and tags to the release policy, enable required reviewers if desired, and allow only the release workflow to use it.

Make these Actions secrets available to the MClash repository:

| Secret | Value |
| --- | --- |
| `CSC_LINK` | Base64-encoded Developer ID Application `.p12` certificate and private key |
| `CSC_KEY_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Ten-character Apple Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | Private Ed25519 key exported by Sparkle's `generate_keys -x` tool |
| `MCLASH_HOST_DEVID_PROFILE` | Base64-encoded Developer ID provisioning profile for the host app |
| `MCLASH_NETWORK_EXTENSION_DEVID_PROFILE` | Base64-encoded Developer ID provisioning profile for the Network Extension |

The existing organization-level Apple secrets may be reused. Set their visibility to **Selected repositories** and include MClash instead of exposing them to every public repository in the organization. `GITHUB_TOKEN` is supplied automatically and should not be added as a secret.

The Sparkle public key matching `SPARKLE_PRIVATE_KEY` must be committed as `SUPublicEDKey` in `Support/Info.plist`. Never commit the private key, `.p12`, its password, or Apple app-specific password.

## Release policy

- Release versions use semantic tags such as `v1.0.0`.
- `CFBundleVersion` is an increasing positive integer. Tag-triggered builds default to the GitHub Actions run number; manual runs may supply a higher value.
- Releases currently support Apple Silicon. Another architecture requires independently reviewed Xray artifacts and acceptance tests.
- A release must originate from a clean commit and have matching notes in `ReleaseNotes/<version>.md`.
- Published assets and tags are immutable. Fix failures in a new version instead of replacing an existing release.

## Validate a signed candidate

Complete the agreed product changes and integrated local acceptance first. In **Actions → Release → Run workflow**, choose the source branch and final version, and leave **candidate_only** enabled. This mode pins the source commit, runs verification, signs and notarizes the package, and uploads an Actions artifact. It does not create a release or tag.

Download that artifact to verify its signature, checksum and real application behavior. Complete any required macOS Network Extension and system proxy acceptance before the public release. The current machine's installed app and routing settings need their own backup and recovery plan for an upgrade test.

## Publishing

The normal path is to push a tag:

```sh
git tag -s v1.0.0 -m "MClash 1.0.0"
git push origin v1.0.0
```

Manual publication requires **candidate_only** to be disabled and the matching tag to exist. The publish step refuses to replace an existing release. The protected `release` environment controls access to signing credentials.

The workflow performs these operations:

1. Strict Swift 6 compiler checks and the complete unit test suite on an Apple Silicon runner.
2. Pinned Xray, routing database and Sparkle artifact checksum verification.
3. Temporary Keychain import of the Developer ID Application certificate.
4. Hardened-runtime signing of Sparkle helpers, the bundled core, and MClash from the inside out.
5. Apple notarization and stapling of both the app and disk image, followed by Gatekeeper assessment.
6. Creation of a compressed APFS DMG with an Applications shortcut and a Sparkle update ZIP.
7. Packaging of Xray and Sparkle license and source notices.
8. Generation, reverse-application, code-signing verification, and Ed25519 signing of delta updates from up to two recent stable builds.
9. Ed25519 signing of the full update through standard input, generation of `appcast.xml`, and SHA-256 checksums.
10. Artifact upload for a candidate, or publication of update, notice and checksum assets for a public release.
11. Destruction of the temporary Keychain and certificate file even if the job fails.

The Release workflow has read-only repository access during tests. Only the protected publishing job receives `contents: write` and release secrets.

## Published assets

Each release contains:

- `MClash-<version>-macos-arm64.dmg` — first-install download.
- `MClash-<version>-macos-arm64.zip` — Sparkle update archive.
- `MClash-<version>-from-<old-version>-macos-arm64.delta` — optional verified incremental update for a recent build.
- `appcast.xml` — signed Sparkle update feed.
- `Sparkle-2.9.4-LICENSE.txt` — Sparkle's MIT license notice.
- `SHA256SUMS` — hashes for the public artifacts.

The full ZIP is always published and remains the fallback. Sparkle selects a delta only when its `deltaFrom` build matches the installed build; if applying the delta fails, Sparkle automatically retries with the full archive. Failure to produce a valid, smaller delta therefore warns during packaging but does not block a safe full update.

The application reads the stable feed URL:

```text
https://github.com/leaperone/MClash/releases/latest/download/appcast.xml
```

The appcast itself points to the immutable versioned Release URL, so replacing a tag or asset after publication is prohibited except to recover a failed first publication before users have downloaded it.
