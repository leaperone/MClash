#!/bin/zsh
set -euo pipefail
repo_root="${MCLASH_RELEASE_PREFLIGHT_REPO_ROOT:-${0:A:h:h}}"
source "${repo_root}/Support/xray.env"
version="${1:?Pass the 1.6 release version}"
evidence="${2:-${repo_root}/ReleaseEvidence/${version}.json}"
python3 - "${repo_root}" "${version}" "${evidence}" "${XRAY_VERSION}" "${XRAY_REVISION}" "${XRAY_RAW_SHA256}" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

root, version, path, xray_version, xray_revision, xray_hash = sys.argv[1:]
root = pathlib.Path(root).resolve()
path = pathlib.Path(path).resolve()
if not re.fullmatch(r"1\.6\.\d+(?:-[0-9A-Za-z.-]+)?", version):
    raise SystemExit("Xray release preflight requires a 1.6 version")
try:
    relative = path.relative_to(root).as_posix()
    evidence = json.loads(path.read_text())
except (OSError, ValueError) as error:
    raise SystemExit(f"Missing or invalid release evidence: {error}")

def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()

status = git("status", "--porcelain")
if status:
    raise SystemExit("Release preflight requires a clean worktree; commit evidence before running it")

head = git("rev-parse", "HEAD")
commit = evidence.get("commit")
if commit != head:
    if len(git("rev-list", "--parents", "-n", "1", "HEAD").split()) != 2:
        raise SystemExit("Evidence-only commit cannot be a merge commit")
    parent = git("rev-parse", "HEAD^")
    changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").splitlines()
    if commit != parent or changed != [relative]:
        raise SystemExit("Evidence must match HEAD or the parent of an evidence-only commit")
expected = {
    "schema_version": 1,
    "release_version": version,
    "status": "passed",
    "backend": "xray",
    "xray_version": xray_version,
    "xray_revision": xray_revision,
    "xray_raw_sha256": xray_hash,
}
for key, value in expected.items():
    if evidence.get(key) != value:
        raise SystemExit(f"Release evidence does not match {key}")
required = {"nodeSources", "groupSelect", "groupFallback", "groupURLTest", "routingRules", "httpIngress", "socksIngress", "dnsPolicy"}
if not required.issubset(set(evidence.get("capabilities", []))):
    raise SystemExit("Release evidence is missing required Xray runtime capabilities")
commands = evidence.get("validation_commands")
if not isinstance(commands, list) or not commands or not all(isinstance(c, str) and c.strip() for c in commands):
    raise SystemExit("Release evidence must list actual validation commands")
if not (root / "ReleaseNotes" / f"{version}.md").is_file():
    raise SystemExit("Release notes are missing")
print(f"Xray release preflight passed for {version} at {head}")
PY
