#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
release_base="https://github.com/MetaCubeX/mihomo/releases/download/Prerelease-Alpha"
version="$(curl -fsSL "${release_base}/version.txt")"
architecture="$(uname -m)"

case "${architecture}" in
  arm64)
    upstream_name="mihomo-darwin-arm64-${version}.gz"
    resource_name="mihomo-alpha-darwin-arm64"
    ;;
  x86_64)
    upstream_name="mihomo-darwin-amd64-compatible-${version}.gz"
    resource_name="mihomo-alpha-darwin-amd64-compatible"
    ;;
  *)
    print -u2 "Unsupported macOS architecture: ${architecture}"
    exit 1
    ;;
esac

resource_dir="${repo_root}/Sources/MClashApp/Resources/Core"
license_dir="${repo_root}/Sources/MClashApp/Resources/ThirdParty"
download_dir="$(mktemp -d)"
trap 'rm -rf "${download_dir}"' EXIT

mkdir -p "${resource_dir}" "${license_dir}"
curl -fL "${release_base}/${upstream_name}" -o "${download_dir}/${upstream_name}"
curl -fsSL "${release_base}/checksums.txt" -o "${download_dir}/checksums.txt"

expected_hash="$(awk -v file="./${upstream_name}" '$2 == file { print $1 }' "${download_dir}/checksums.txt")"
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

gzip -dc "${download_dir}/${upstream_name}" > "${resource_dir}/${resource_name}"
chmod 755 "${resource_dir}/${resource_name}"
curl -fsSL "https://raw.githubusercontent.com/MetaCubeX/mihomo/Alpha/LICENSE" \
  -o "${license_dir}/mihomo-LICENSE.txt"

print "Installed ${resource_name} (${version}, ${actual_hash})"
