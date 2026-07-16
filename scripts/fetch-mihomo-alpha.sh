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
release_base="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_ALPHA_RELEASE_TAG}"
recorded_raw_hash="$(mihomo_alpha_recorded_hash "${MIHOMO_ALPHA_RESOURCE_NAME}")"
if [[ -z "${recorded_raw_hash}" ]]; then
  print -u2 "No reviewed raw SHA-256 is recorded for ${MIHOMO_ALPHA_RESOURCE_NAME}."
  print -u2 "Add the independently reviewed hash to Support/mihomo-alpha.sha256 before fetching."
  exit 1
fi

resource_dir="${repo_root}/Sources/MClashApp/Resources/Core"
license_dir="${repo_root}/Sources/MClashApp/Resources/ThirdParty"
download_dir="$(mktemp -d)"
trap 'rm -rf "${download_dir}"' EXIT

mkdir -p "${resource_dir}" "${license_dir}"
upstream_name="${MIHOMO_ALPHA_UPSTREAM_NAME}"
resource_name="${MIHOMO_ALPHA_RESOURCE_NAME}"

curl -fL "${release_base}/${upstream_name}" -o "${download_dir}/${upstream_name}"
curl -fsSL "${release_base}/checksums.txt" -o "${download_dir}/checksums.txt"

expected_hash="$(awk -v file="${upstream_name}" \
  '$2 == file || $2 == "./" file { print $1; exit }' \
  "${download_dir}/checksums.txt")"
if [[ -z "${expected_hash}" ]]; then
  print -u2 "No checksum was published for ${upstream_name}"
  exit 1
fi

actual_hash="$(shasum -a 256 "${download_dir}/${upstream_name}" | awk '{ print $1 }')"
if [[ "${actual_hash}" != "${expected_hash}" ]]; then
  print -u2 "Checksum mismatch for ${upstream_name}"
  print -u2 "Expected: ${expected_hash}"
  print -u2 "Actual:   ${actual_hash}"
  exit 1
fi

gzip -t "${download_dir}/${upstream_name}"
gzip -dc "${download_dir}/${upstream_name}" > "${download_dir}/${resource_name}"
chmod 755 "${download_dir}/${resource_name}"
raw_hash="$(shasum -a 256 "${download_dir}/${resource_name}" | awk '{ print $1 }')"
if [[ "${raw_hash}" != "${recorded_raw_hash}" ]]; then
  print -u2 "Downloaded core does not match the recorded raw SHA-256 for ${resource_name}"
  print -u2 "Expected: ${recorded_raw_hash}"
  print -u2 "Actual:   ${raw_hash}"
  exit 1
fi

curl -fsSL "https://raw.githubusercontent.com/MetaCubeX/mihomo/${MIHOMO_ALPHA_REVISION}/LICENSE" \
  -o "${download_dir}/mihomo-LICENSE.txt"

# Replace repository artifacts only after the pinned archive and license have
# both downloaded and the published archive checksum has been verified.
mv -f "${download_dir}/${resource_name}" "${resource_dir}/${resource_name}"
mv -f "${download_dir}/mihomo-LICENSE.txt" "${license_dir}/mihomo-LICENSE.txt"
mihomo_alpha_verify_selected_artifact

print "Installed ${resource_name} (${MIHOMO_ALPHA_VERSION}, raw SHA-256 ${raw_hash})"
