#!/bin/zsh
set -euo pipefail

# Launches an isolated host instance and exercises the read-only automation
# endpoint.  This script intentionally does not use `open` or the installed
# application: the built bundle is launched directly with a private namespace
# so production MClash state, locks, keychain tokens, and sockets are not
# involved.
repo_root="${0:A:h:h}"
app_bundle="${MCLASH_APP_PATH:-${repo_root}/.build/release/MClash.app}"
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
log_file="${automation_directory}/mclash.log"
app_pid=""

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
  rm -rf "${automation_directory}"
}
trap cleanup EXIT INT TERM

MCLASH_TEST_MODE=1 \
MCLASH_NATIVE_RUNTIME=1 \
MCLASH_INSTANCE_NAMESPACE="${namespace}" \
MCLASH_APPLICATION_SUPPORT_IDENTIFIER="${namespace}" \
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

response="$("${cli}" runtime-diagnostics --socket "${socket_path}" --pretty \
  --timeout "${MCLASH_SMOKE_TIMEOUT_SECONDS:-30}")"
print -r -- "${response}"

/usr/bin/python3 - "${response}" <<'PY'
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
PY

print "Native runtime CLI smoke passed (namespace=${namespace})."
