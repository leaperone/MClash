#!/bin/zsh

# Shared artifact selection and verification. Callers must set `repo_root`
# before sourcing this file.
if [[ -z "${repo_root:-}" ]]; then
  print -u2 "mihomo-alpha-common.sh requires repo_root"
  return 1 2>/dev/null || exit 1
fi

source "${repo_root}/Support/mihomo-alpha.env"

mihomo_alpha_select_architecture() {
  local architecture="${1:-$(uname -m)}"

  case "${architecture}" in
    arm64)
      MIHOMO_ALPHA_ARCHITECTURE="arm64"
      MIHOMO_ALPHA_UPSTREAM_NAME="mihomo-darwin-arm64-${MIHOMO_ALPHA_VERSION}.gz"
      MIHOMO_ALPHA_RESOURCE_NAME="mihomo-alpha-darwin-arm64"
      ;;
    x86_64|amd64)
      MIHOMO_ALPHA_ARCHITECTURE="x86_64"
      MIHOMO_ALPHA_UPSTREAM_NAME="mihomo-darwin-amd64-compatible-${MIHOMO_ALPHA_VERSION}.gz"
      MIHOMO_ALPHA_RESOURCE_NAME="mihomo-alpha-darwin-amd64-compatible"
      ;;
    *)
      print -u2 "Unsupported macOS architecture: ${architecture}"
      return 1
      ;;
  esac

  MIHOMO_ALPHA_RESOURCE_PATH="${repo_root}/Sources/MClashApp/Resources/Core/${MIHOMO_ALPHA_RESOURCE_NAME}"
}

mihomo_alpha_recorded_hash() {
  local resource_name="$1"
  local manifest="${repo_root}/Support/mihomo-alpha.sha256"

  [[ -f "${manifest}" ]] || return 0
  awk -v file="${resource_name}" \
    '$2 == file || $2 == "*" file { print $1; exit }' \
    "${manifest}"
}

mihomo_alpha_verify_selected_artifact() {
  local artifact="${MIHOMO_ALPHA_RESOURCE_PATH}"
  local expected_hash
  local actual_hash

  if [[ ! -f "${artifact}" ]]; then
    print -u2 "Missing bundled mihomo Alpha core: ${artifact}"
    return 1
  fi

  expected_hash="$(mihomo_alpha_recorded_hash "${MIHOMO_ALPHA_RESOURCE_NAME}")"
  if [[ -z "${expected_hash}" ]]; then
    print -u2 "No recorded SHA-256 for ${MIHOMO_ALPHA_RESOURCE_NAME} in Support/mihomo-alpha.sha256"
    return 1
  fi
  if [[ "${#expected_hash}" -ne 64 ]]; then
    print -u2 "Invalid recorded SHA-256 for ${MIHOMO_ALPHA_RESOURCE_NAME}"
    return 1
  fi

  actual_hash="$(shasum -a 256 "${artifact}" | awk '{ print $1 }')"
  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    print -u2 "Bundled mihomo Alpha SHA-256 mismatch: ${MIHOMO_ALPHA_RESOURCE_NAME}"
    print -u2 "Expected: ${expected_hash}"
    print -u2 "Actual:   ${actual_hash}"
    return 1
  fi

  if [[ ! -x "${artifact}" ]]; then
    print -u2 "Bundled mihomo Alpha core is not executable: ${artifact}"
    return 1
  fi

  print "Verified ${MIHOMO_ALPHA_RESOURCE_NAME} (${MIHOMO_ALPHA_VERSION}, ${actual_hash})"
}
