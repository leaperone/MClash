#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
source "${repo_root}/scripts/xray-common.sh"
[[ $# -eq 0 ]] || { print -u2 "Usage: ${0:t}"; exit 2; }
xray_verify_selected_artifact
"${XRAY_RESOURCE_PATH}" version
"${XRAY_RESOURCE_PATH}" help api bo >/dev/null
