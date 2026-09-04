#!/bin/zsh
set -euo pipefail

# Release metadata gate for the native 1.5.x line.  This intentionally does
# not change the app's current version; it only proves that a release commit
# carries an explicit, machine-readable native validation record.
repo_root="${MCLASH_RELEASE_PREFLIGHT_REPO_ROOT:-${0:A:h:h}}"
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
parent_commit="$(git -C "${repo_root}" rev-parse HEAD^ 2>/dev/null || true)"
python3 - "${repo_root}" "${version}" "${evidence_file}" "${expected_commit}" "${parent_commit}" <<'PY'
import json
import pathlib
import sys

repo_root, version, evidence_path, expected_commit, parent_commit = sys.argv[1:]
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
evidence_commit = evidence.get("commit")
if evidence_commit != expected_commit:
    # A tracked evidence file cannot contain the final commit SHA: adding the
    # file changes that SHA.  Permit the tested parent commit only when the
    # release commit adds exactly this evidence file and no code or metadata
    # change.  This makes the evidence-only commit explicit and prevents a
    # later release commit from silently reusing an older report.
    if evidence_commit != parent_commit:
        raise SystemExit(
            "Native evidence commit does not match the checked-out release "
            "commit or its evidence-only parent"
        )
    repo = pathlib.Path(repo_root).resolve()
    evidence_path_obj = pathlib.Path(evidence_path).resolve()
    try:
        relative_evidence = evidence_path_obj.relative_to(repo)
    except ValueError:
        raise SystemExit("Native evidence must be inside the release checkout")
    import subprocess
    changed = subprocess.check_output(
        ["git", "-C", str(repo), "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"],
        text=True,
    ).splitlines()
    if changed != [relative_evidence.as_posix()]:
        raise SystemExit(
            "Evidence-parent mode requires the release commit to add only "
            f"{relative_evidence.as_posix()}"
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
