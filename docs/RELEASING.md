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

The existing organization-level Apple secrets may be reused. Set their visibility to **Selected repositories** and include MClash instead of exposing them to every public repository in the organization. `GITHUB_TOKEN` is supplied automatically and should not be added as a secret.

The Sparkle public key matching `SPARKLE_PRIVATE_KEY` must be committed as `SUPublicEDKey` in `Support/Info.plist`. Never commit the private key, `.p12`, its password, or Apple app-specific password.

## Release policy

- Release versions use semantic tags such as `v1.0.0`.
- `CFBundleVersion` is an increasing positive integer. Tag-triggered builds default to the GitHub Actions run number; manual runs may supply a higher value.
- Releases are Apple Silicon-only until the Intel mihomo artifact has an independently reviewed checksum in the repository.
- A release must originate from a clean commit and have matching notes in `ReleaseNotes/<version>.md`.

## Publishing

The normal path is to push a tag:

```sh
git tag -s v1.0.0 -m "MClash 1.0.0"
git push origin v1.0.0
```

Alternatively, open **Actions → Release → Run workflow**, enter the version and optional build number, then approve the protected `release` environment. Manual dispatch creates the GitHub tag when the Release is published.

The workflow performs these operations:

1. Strict Swift 6 compiler checks and the complete unit test suite on an Apple Silicon runner.
2. Pinned mihomo and Sparkle artifact checksum verification.
3. Temporary Keychain import of the Developer ID Application certificate.
4. Hardened-runtime signing of Sparkle helpers, the bundled core, and MClash from the inside out.
5. Apple notarization and stapling of both the app and disk image, followed by Gatekeeper assessment.
6. Creation of a compressed APFS DMG with an Applications shortcut and a Sparkle update ZIP.
7. Packaging of the complete source tree for the exact bundled mihomo revision and Sparkle's MIT notice.
8. Ed25519 signing of the update through standard input, generation of `appcast.xml`, and SHA-256 checksums.
9. Publication of all runtime, update, corresponding-source, notice, and checksum assets to the same GitHub Release.
10. Destruction of the temporary Keychain and certificate file even if the job fails.

The Release workflow has read-only repository access during tests. Only the protected publishing job receives `contents: write` and release secrets.

## Published assets

Each release contains:

- `MClash-<version>-macos-arm64.dmg` — first-install download.
- `MClash-<version>-macos-arm64.zip` — Sparkle update archive.
- `appcast.xml` — signed Sparkle update feed.
- `mihomo-<revision>-source.tar.gz` — complete corresponding source for the bundled GPL-3.0 core.
- `Sparkle-2.9.4-LICENSE.txt` — Sparkle's MIT license notice.
- `SHA256SUMS` — hashes for the public artifacts.

The application reads the stable feed URL:

```text
https://github.com/leaperone/MClash/releases/latest/download/appcast.xml
```

The appcast itself points to the immutable versioned Release URL, so replacing a tag or asset after publication is prohibited except to recover a failed first publication before users have downloaded it.
