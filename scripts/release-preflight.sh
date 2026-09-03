#!/bin/zsh
set -euo pipefail

# Release metadata gate for the native 1.5.x line.  This intentionally does
# not change the app's current version; it only proves that a release commit
# carries an explicit, machine-readable native validation record.
repo_root="${0:A:h:h}"
version="${1:-}"
evidence_file="${2:-}"
release_notes="${3:-${repo_root}/ReleaseNotes/${version}.md}"

if [[ -z "${version}" || -z "${evidence_file}" ]]; then
  print -u2 "Usage: ${0:t} <1.5.x-version> <native-evidence.json> [release-notes]"
  exit 2
fi

if [[ ! "${version}" =~ '^1\.5\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "The native release gate only accepts an explicit 1.5.x version: ${version}"
  exit 1
fi
if [[ ! -s "${release_notes}" ]]; then
  print -u2 "Release notes are required for ${version}: ${release_notes}"
  exit 1
fi
if [[ ! -s "${evidence_file}" ]]; then
  print -u2 "Native capability evidence is required: ${evidence_file}"
  print -u2 "Run the isolated native validation and commit its report before releasing."
  exit 1
fi

expected_commit="$(git -C "${repo_root}" rev-parse HEAD)"
python3 - "${version}" "${evidence_file}" "${expected_commit}" <<'PY'
import json
import pathlib
import sys

version, evidence_path, expected_commit = sys.argv[1:]
try:
    evidence = json.loads(pathlib.Path(evidence_path).read_text())
except Exception as exc:
    raise SystemExit(f"Invalid native capability evidence JSON: {exc}")

if evidence.get("schema_version") != 1:
    raise SystemExit("Native capability evidence must use schema_version 1")
if evidence.get("release_version") != version:
    raise SystemExit(
        f"Native evidence release_version does not match {version}: "
        f"{evidence.get('release_version')!r}"
    )
if evidence.get("commit") != expected_commit:
    raise SystemExit(
        "Native evidence commit does not match the checked-out release commit"
    )
if evidence.get("status") != "passed":
    raise SystemExit("Native capability evidence status must be 'passed'")
if evidence.get("backend") != "native":
    raise SystemExit("Native capability evidence backend must be 'native'")

capabilities = set(evidence.get("capabilities", []))
required = {"nativeRuntime", "nativeRouting", "nativeDNS"}
missing = sorted(required - capabilities)
if missing:
    raise SystemExit("Native capability evidence is missing: " + ", ".join(missing))

commands = evidence.get("validation_commands")
if not isinstance(commands, list) or not commands or not all(isinstance(c, str) and c.strip() for c in commands):
    raise SystemExit("Native capability evidence must list validation_commands")
PY

print "Native 1.5.x release preflight passed for ${version}."
