#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"

architecture="${MCLASH_CORE_ARCH:-$(uname -m)}"
if [[ "${1:-}" == "--architecture" ]]; then
  if [[ -z "${2:-}" ]]; then
    print -u2 "Usage: ${0:t} [--architecture arm64|x86_64]"
    exit 2
  fi
  architecture="$2"
  shift 2
fi
if (( $# > 0 )); then
  print -u2 "Usage: ${0:t} [--architecture arm64|x86_64]"
  exit 2
fi

mihomo_alpha_select_architecture "${architecture}"
mihomo_alpha_verify_selected_artifact
