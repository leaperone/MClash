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
