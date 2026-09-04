#!/bin/zsh
set -euo pipefail

# Launches an isolated host instance and exercises the read-only automation
# endpoint.  This script intentionally does not use `open` or the installed
# application: the built bundle is launched directly with a private namespace
# so production MClash state, locks, keychain tokens, and sockets are not
# involved.
repo_root="${0:A:h:h}"
if (( $# > 1 )); then
  print -u2 "Usage: ${0:t} [MClash.app]"
  exit 2
fi
app_bundle="${MCLASH_APP_PATH:-${1:-${repo_root}/.build/release/MClash.app}}"
app_executable="${app_bundle}/Contents/MacOS/MClash"
cli="${MCLASH_CLI_PATH:-${app_bundle}/Contents/Helpers/mclashctl}"

[[ -x "${app_executable}" ]] || {
  print -u2 "MClash app executable was not found: ${app_executable}"
  exit 1
}
[[ -x "${cli}" ]] || {
  print -u2 "mclashctl was not found: ${cli}"
  exit 1
}

automation_directory="$(mktemp -d "${TMPDIR:-/tmp}/mclash-native-cli.XXXXXX")"
namespace="mclash-native-cli-${RANDOM}-$$"
application_support_identifier="${namespace}"
shadow_application_support=""
skip_auto_connect=1
if [[ "${MCLASH_SHADOW_AUTO_CONNECT:-0}" == "1" ]]; then
  skip_auto_connect=0
fi
log_file="${automation_directory}/mclash.log"
app_pid=""

# An opt-in copied-profile run stages the user's existing MClash tree under a
# unique Application Support identifier. The source remains read-only and the
# disposable copy is removed during cleanup. Test mode keeps Network Extension
# and System Proxy backends inert, so this cannot reconfigure the live app.
if [[ -n "${MCLASH_SHADOW_SOURCE_ROOT:-}" ]]; then
  [[ -d "${MCLASH_SHADOW_SOURCE_ROOT}" ]] || {
    print -u2 "Shadow source does not exist: ${MCLASH_SHADOW_SOURCE_ROOT}"
    exit 1
  }
  application_support_identifier="MClash-Shadow-${RANDOM}-$$"
  shadow_application_support="${HOME}/Library/Application Support/${application_support_identifier}"
  # Copy only authoritative configuration and node-source material. Runtime,
  # settings and stale system-proxy state are intentionally excluded so a
  # shadow run cannot inherit an old activation or malformed legacy override.
  mkdir -p "${shadow_application_support}"
  if [[ -d "${MCLASH_SHADOW_SOURCE_ROOT}/Configuration" ]]; then
    /usr/bin/ditto "${MCLASH_SHADOW_SOURCE_ROOT}/Configuration" \
      "${shadow_application_support}/Configuration"
  fi
  if [[ -d "${MCLASH_SHADOW_SOURCE_ROOT}/Profiles" ]]; then
    /usr/bin/ditto "${MCLASH_SHADOW_SOURCE_ROOT}/Profiles" \
      "${shadow_application_support}/Profiles"
  fi
  if [[ -f "${MCLASH_SHADOW_SOURCE_ROOT}/State/active-profile.json" ]]; then
    mkdir -p "${shadow_application_support}/State"
    /usr/bin/ditto "${MCLASH_SHADOW_SOURCE_ROOT}/State/active-profile.json" \
      "${shadow_application_support}/State/active-profile.json"
  fi
  shadow_manifest="${shadow_application_support}/Configuration/manifest.json"
  if [[ -f "${shadow_manifest}" ]]; then
    # The production document may intentionally expose a LAN bind address;
    # native shadow listeners are loopback-only and must never open LAN ports.
    /usr/bin/python3 - "${shadow_manifest}" <<'PY'
import json
import random
import sys
from pathlib import Path

path = Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
reserved = set()
for entrance in document.get("entrances", []):
    if isinstance(entrance, dict):
        entrance["bindAddress"] = "127.0.0.1"
        kind = str(entrance.get("kind", "")).lower()
        if entrance.get("enabled") and kind in {"http", "socks5"}:
            while True:
                port = random.randint(20_000, 60_000)
                if port not in reserved:
                    reserved.add(port)
                    entrance["port"] = port
                    break
path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
  fi
fi

# Launch Services uses the bundle identifier even when an executable is
# invoked directly.  The built app intentionally keeps the production
# identifier, and its LSMultipleInstancesProhibited policy means macOS can
# SIGKILL a second process while the installed MClash is running.  Stage a
# private bundle with a unique identifier so this smoke test is genuinely
# isolated from the production application.  Do not mutate the build output.
isolated_app_bundle="${automation_directory}/MClash-isolated.app"
/usr/bin/ditto "${app_bundle}" "${isolated_app_bundle}"
/usr/bin/plutil -replace CFBundleIdentifier -string "one.leaper.mclash.${namespace}" \
  "${isolated_app_bundle}/Contents/Info.plist"
/usr/bin/plutil -replace LSMultipleInstancesProhibited -bool false \
  "${isolated_app_bundle}/Contents/Info.plist"
# Editing Info.plist invalidates the copied bundle's sealed code resources.
# Re-sign the disposable bundle so AppKit accepts it; this is ad-hoc only and
# never changes the production app or the release artifact.
/usr/bin/codesign --force --deep --sign - "${isolated_app_bundle}"
app_executable="${isolated_app_bundle}/Contents/MacOS/MClash"
cli="${isolated_app_bundle}/Contents/Helpers/mclashctl"

cleanup() {
  if [[ -n "${app_pid}" ]] && kill -0 "${app_pid}" 2>/dev/null; then
    kill -TERM "${app_pid}" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "${app_pid}" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "${app_pid}" 2>/dev/null || true
    wait "${app_pid}" 2>/dev/null || true
  fi
  if [[ "${MCLASH_KEEP_SHADOW:-0}" != "1" ]] && [[ -n "${shadow_application_support}" ]] &&
     [[ "${shadow_application_support}" == "${HOME}/Library/Application Support/MClash-Shadow-"* ]]; then
    rm -rf "${shadow_application_support}"
  fi
  [[ "${MCLASH_KEEP_SHADOW:-0}" == "1" ]] || rm -rf "${automation_directory}"
}
trap cleanup EXIT INT TERM

MCLASH_TEST_MODE=1 \
MCLASH_NATIVE_RUNTIME=1 \
MCLASH_SKIP_AUTO_CONNECT="${skip_auto_connect}" \
MCLASH_SKIP_SOURCE_SYNCHRONIZATION=1 \
MCLASH_INSTANCE_NAMESPACE="${namespace}" \
MCLASH_APPLICATION_SUPPORT_IDENTIFIER="${application_support_identifier}" \
MCLASH_AUTOMATION_DIRECTORY_PATH="${automation_directory}" \
  "${app_executable}" --mclash-background --mclash-test-instance \
  >"${log_file}" 2>&1 &
app_pid=$!

endpoint_file="${automation_directory}/endpoint.json"
deadline=$((SECONDS + ${MCLASH_SMOKE_TIMEOUT_SECONDS:-30}))
while (( SECONDS < deadline )); do
  if [[ -s "${endpoint_file}" ]]; then
    break
  fi
  if ! kill -0 "${app_pid}" 2>/dev/null; then
    print -u2 "Isolated MClash exited before publishing automation endpoint."
    sed -n '1,120p' "${log_file}" >&2 || true
    exit 1
  fi
  sleep 0.1
done
[[ -s "${endpoint_file}" ]] || {
  print -u2 "Timed out waiting for isolated automation endpoint."
  sed -n '1,120p' "${log_file}" >&2 || true
  exit 1
}

socket_path="$(/usr/bin/python3 - "${endpoint_file}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    endpoint = json.load(stream)
socket = endpoint.get("socketPath")
if not isinstance(socket, str) or not socket.startswith("/"):
    raise SystemExit("endpoint.json has no absolute socketPath")
print(socket)
PY
)"

response=""
if [[ "${MCLASH_SHADOW_AUTO_CONNECT:-0}" == "1" ]]; then
  connect_deadline=$((SECONDS + ${MCLASH_SMOKE_TIMEOUT_SECONDS:-30}))
  while (( SECONDS < connect_deadline )); do
    response="$("${cli}" runtime-diagnostics --socket "${socket_path}" --pretty \
      --timeout "${MCLASH_SMOKE_TIMEOUT_SECONDS:-30}")"
    state="$(/usr/bin/python3 - "${response}" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("result", {}).get("state", ""))
except Exception:
    print("")
PY
)"
    [[ "${state}" == "running" ]] && break
    sleep 0.2
  done
else
  response="$("${cli}" runtime-diagnostics --socket "${socket_path}" --pretty \
    --timeout "${MCLASH_SMOKE_TIMEOUT_SECONDS:-30}")"
fi
print -r -- "${response}"

/usr/bin/python3 - "${response}" "${MCLASH_SHADOW_SOURCE_ROOT:-}" "${MCLASH_SHADOW_AUTO_CONNECT:-0}" <<'PY'
import json
import sys

response = json.loads(sys.argv[1])
if response.get("error") is not None:
    raise SystemExit("runtime.diagnostics returned an RPC error")
diagnostics = response.get("result")
if not isinstance(diagnostics, dict):
    raise SystemExit("runtime.diagnostics returned no result object")
if diagnostics.get("backend") != "native":
    raise SystemExit("isolated runtime backend was not native")
capabilities = diagnostics.get("capabilities", [])
required = {"nativeRuntime", "nativeRouting"}
if not required.issubset(set(capabilities)):
    raise SystemExit("native runtime capabilities are incomplete")
if sys.argv[2]:
    revision = diagnostics.get("workspaceRevision")
    if not isinstance(revision, int) or revision <= 0 or not diagnostics.get("hasCompiledRuntimePlan"):
        raise SystemExit("copied-profile shadow did not load a compiled workspace plan")
if sys.argv[3] == "1":
    if diagnostics.get("state") != "running" or not diagnostics.get("startedAt"):
        raise SystemExit("native shadow auto-connect did not reach a running state")
PY

print "Native runtime CLI smoke passed (namespace=${namespace})."
if [[ "${MCLASH_KEEP_SHADOW:-0}" == "1" ]]; then
  print "Kept shadow artifacts: appSupport=${shadow_application_support:-none} automation=${automation_directory}"
fi
