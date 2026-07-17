#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"
output="${1:-}"

if [[ -z "${output}" ]]; then
  print -u2 "Usage: package-mihomo-source.sh OUTPUT_TAR_GZ"
  exit 2
fi
if [[ ! "${MIHOMO_ALPHA_REVISION}" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "Pinned mihomo revision is invalid: ${MIHOMO_ALPHA_REVISION}"
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-mihomo-source.XXXXXX")"
checkout="${work_dir}/mihomo"
mkdir -p "${checkout}" "${output:h}"
git -C "${checkout}" init --quiet
git -C "${checkout}" remote add origin https://github.com/MetaCubeX/mihomo.git
git -C "${checkout}" fetch --quiet --depth 1 origin "${MIHOMO_ALPHA_REVISION}"
git -C "${checkout}" checkout --quiet --detach FETCH_HEAD

actual_revision="$(git -C "${checkout}" rev-parse HEAD)"
if [[ "${actual_revision}" != "${MIHOMO_ALPHA_REVISION}" ]]; then
  print -u2 "Fetched mihomo revision changed: ${actual_revision}"
  exit 1
fi
if [[ ! -s "${checkout}/LICENSE" || ! -s "${checkout}/go.mod" ]]; then
  print -u2 "Fetched mihomo source tree is incomplete."
  exit 1
fi

prefix="mihomo-${MIHOMO_ALPHA_REVISION}/"
git -C "${checkout}" archive --format=tar --prefix="${prefix}" HEAD | gzip -9 -n > "${output}"
if [[ ! -s "${output}" ]]; then
  print -u2 "Failed to create corresponding source archive: ${output}"
  exit 1
fi
if ! tar -tzf "${output}" | grep -Fqx "${prefix}go.mod"; then
  print -u2 "Corresponding source archive validation failed."
  exit 1
fi

print "mihomo corresponding source ready: ${output}"
