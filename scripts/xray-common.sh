#!/bin/zsh
if [[ -z "${repo_root:-}" ]]; then
  print -u2 "xray-common.sh requires repo_root"
  return 1 2>/dev/null || exit 1
fi
source "${repo_root}/Support/xray.env"
XRAY_RESOURCE_NAME='xray-darwin-arm64'
XRAY_RESOURCE_PATH="${repo_root}/Sources/MClashApp/Resources/Core/${XRAY_RESOURCE_NAME}"
XRAY_GEOIP_RESOURCE_NAME='xray-geoip.dat'
XRAY_GEOSITE_RESOURCE_NAME='xray-geosite.dat'
XRAY_GEOIP_RESOURCE_PATH="${repo_root}/Sources/MClashApp/Resources/Core/${XRAY_GEOIP_RESOURCE_NAME}"
XRAY_GEOSITE_RESOURCE_PATH="${repo_root}/Sources/MClashApp/Resources/Core/${XRAY_GEOSITE_RESOURCE_NAME}"
xray_recorded_hash() {
  awk -v file="$1" '$2 == file || $2 == "*" file { print $1; exit }' "${repo_root}/Support/xray.sha256"
}
xray_verify_selected_artifact() {
  [[ -f "${XRAY_RESOURCE_PATH}" ]] || { print -u2 "Missing Xray core: ${XRAY_RESOURCE_PATH}"; return 1; }
  [[ -x "${XRAY_RESOURCE_PATH}" ]] || { print -u2 "Xray core is not executable: ${XRAY_RESOURCE_PATH}"; return 1; }
  local expected="$(xray_recorded_hash "${XRAY_RESOURCE_NAME}")"
  local actual="$(shasum -a 256 "${XRAY_RESOURCE_PATH}" | awk '{print $1}')"
  [[ "${#expected}" -eq 64 ]] || { print -u2 "Invalid Xray SHA-256 manifest"; return 1; }
  [[ "${actual}" == "${expected}" ]] || { print -u2 "Xray raw SHA-256 mismatch"; return 1; }
  print "Verified ${XRAY_RESOURCE_NAME} (${XRAY_VERSION}, ${actual})"
}

xray_recorded_geo_hash() {
  awk -v file="$1" '$2 == file || $2 == "*" file { print $1; exit }' "${repo_root}/Support/xray.sha256"
}

xray_verify_geodata_artifacts() {
  local file expected actual
  for pair in \
    "${XRAY_GEOIP_RESOURCE_NAME}:${XRAY_GEOIP_RESOURCE_PATH}" \
    "${XRAY_GEOSITE_RESOURCE_NAME}:${XRAY_GEOSITE_RESOURCE_PATH}"
  do
    file="${pair%%:*}"
    local artifact_path="${pair#*:}"
    [[ -s "${artifact_path}" ]] || { print -u2 "Missing Xray GEO database: ${artifact_path}"; return 1; }
    expected="$(xray_recorded_geo_hash "${file}")"
    actual="$(shasum -a 256 "${artifact_path}" | awk '{print $1}')"
    [[ "${#expected}" -eq 64 && "${actual}" == "${expected}" ]] || {
      print -u2 "Xray GEO database SHA-256 mismatch: ${file}"
      return 1
    }
  done
  print "Verified Xray GEO databases"
}
