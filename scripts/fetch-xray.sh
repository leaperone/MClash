#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
source "${repo_root}/scripts/xray-common.sh"
[[ $# -eq 0 ]] || { print -u2 "Usage: ${0:t}"; exit 2; }
base="https://github.com/XTLS/Xray-core/releases/download/${XRAY_RELEASE_TAG}"
download_dir="$(mktemp -d)"
trap 'rm -rf "${download_dir}"' EXIT
archive="${download_dir}/${XRAY_UPSTREAM_ARCHIVE}"
curl -fL "${base}/${XRAY_UPSTREAM_ARCHIVE}" -o "${archive}"
curl -fL "${base}/${XRAY_UPSTREAM_ARCHIVE}.dgst" -o "${archive}.dgst"
published="$(awk -F'= ' '/^SHA2-256=/{print $2}' "${archive}.dgst")"
actual_archive="$(shasum -a 256 "${archive}" | awk '{print $1}')"
[[ "${published}" == "${actual_archive}" ]] || { print -u2 "Xray archive checksum mismatch"; exit 1; }
[[ "${actual_archive}" == "${XRAY_ARCHIVE_SHA256}" ]] || { print -u2 "Xray archive differs from pinned checksum"; exit 1; }
unzip -p "${archive}" xray > "${download_dir}/${XRAY_RESOURCE_NAME}"
unzip -p "${archive}" geoip.dat > "${download_dir}/${XRAY_GEOIP_RESOURCE_NAME}"
unzip -p "${archive}" geosite.dat > "${download_dir}/${XRAY_GEOSITE_RESOURCE_NAME}"
chmod 755 "${download_dir}/${XRAY_RESOURCE_NAME}"
raw="$(shasum -a 256 "${download_dir}/${XRAY_RESOURCE_NAME}" | awk '{print $1}')"
[[ "${raw}" == "${XRAY_RAW_SHA256}" ]] || { print -u2 "Xray raw binary checksum mismatch"; exit 1; }
for pair in \
  "${XRAY_GEOIP_RESOURCE_NAME}:${XRAY_GEOIP_RESOURCE_PATH}" \
  "${XRAY_GEOSITE_RESOURCE_NAME}:${XRAY_GEOSITE_RESOURCE_PATH}"
do
  name="${pair%%:*}"
  path="${pair#*:}"
  hash="$(shasum -a 256 "${download_dir}/${name}" | awk '{print $1}')"
  [[ "${hash}" == "$(xray_recorded_geo_hash "${name}")" ]] || { print -u2 "Xray GEO database checksum mismatch: ${name}"; exit 1; }
  chmod 644 "${download_dir}/${name}"
done
mkdir -p "${repo_root}/Sources/MClashApp/Resources/Core"
mv -f "${download_dir}/${XRAY_RESOURCE_NAME}" "${XRAY_RESOURCE_PATH}"
mv -f "${download_dir}/${XRAY_GEOIP_RESOURCE_NAME}" "${XRAY_GEOIP_RESOURCE_PATH}"
mv -f "${download_dir}/${XRAY_GEOSITE_RESOURCE_NAME}" "${XRAY_GEOSITE_RESOURCE_PATH}"
xray_verify_selected_artifact
xray_verify_geodata_artifacts
