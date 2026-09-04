#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-release-preflight.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

notes="${tmp_dir}/1.5.0.md"
evidence="${tmp_dir}/1.5.0.json"
print '# MClash 1.5.0' > "${notes}"
commit="$(git -C "${repo_root}" rev-parse HEAD)"
python3 - "${evidence}" "${commit}" <<'PY'
import json
import pathlib
import sys

path, commit = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "schema_version": 1,
    "release_version": "1.5.0",
    "commit": commit,
    "status": "passed",
    "backend": "native",
    "capabilities": ["nativeRuntime", "nativeRouting", "nativeDNS"],
    "validation_commands": ["./scripts/typecheck.sh", "./scripts/integration-test.sh"],
}, indent=2) + "\n")
PY

"${repo_root}/scripts/release-preflight.sh" 1.5.0 "${evidence}" "${notes}"
if "${repo_root}/scripts/release-preflight.sh" 1.4.19 "${evidence}" "${notes}" >/dev/null 2>&1; then
  print -u2 "release preflight accepted a non-1.5.x version"
  exit 1
fi
print "Release preflight tests passed."

# Regression: a tracked evidence file is added in an evidence-only commit, so
# its report must bind to the tested parent rather than the impossible final
# SHA. Use a disposable repository to exercise the exact release gate.
fixture_repo="${tmp_dir}/fixture-repo"
mkdir -p "${fixture_repo}/ReleaseEvidence" "${fixture_repo}/ReleaseNotes"
git -C "${fixture_repo}" init -q
git -C "${fixture_repo}" config user.email test@example.invalid
git -C "${fixture_repo}" config user.name "Release Preflight Test"
print '# MClash 1.5.0' > "${fixture_repo}/ReleaseNotes/1.5.0.md"
git -C "${fixture_repo}" add ReleaseNotes/1.5.0.md
git -C "${fixture_repo}" commit -q -m base
tested_commit="$(git -C "${fixture_repo}" rev-parse HEAD)"
python3 - "${fixture_repo}/ReleaseEvidence/1.5.0.json" "${tested_commit}" <<'PY'
import json
import pathlib
import sys
path, commit = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "schema_version": 1,
    "release_version": "1.5.0",
    "commit": commit,
    "status": "passed",
    "backend": "native",
    "capabilities": ["nativeRuntime", "nativeRouting", "nativeDNS"],
    "validation_commands": ["./scripts/test-direct.sh"],
}, indent=2) + "\n")
PY
git -C "${fixture_repo}" add ReleaseEvidence/1.5.0.json
git -C "${fixture_repo}" commit -q -m evidence
MCLASH_RELEASE_PREFLIGHT_REPO_ROOT="${fixture_repo}" \
  "${repo_root}/scripts/release-preflight.sh" \
  1.5.0 "${fixture_repo}/ReleaseEvidence/1.5.0.json" "${fixture_repo}/ReleaseNotes/1.5.0.md"
print "Evidence-only parent commit test passed."

print "unrelated change" > "${fixture_repo}/unrelated.txt"
git -C "${fixture_repo}" add unrelated.txt
git -C "${fixture_repo}" commit -q -m unrelated
if MCLASH_RELEASE_PREFLIGHT_REPO_ROOT="${fixture_repo}" \
  "${repo_root}/scripts/release-preflight.sh" \
  1.5.0 "${fixture_repo}/ReleaseEvidence/1.5.0.json" "${fixture_repo}/ReleaseNotes/1.5.0.md" >/dev/null 2>&1; then
  print -u2 "Evidence-parent mode accepted an unrelated release change"
  exit 1
fi
print "Evidence-only scope rejection test passed."
