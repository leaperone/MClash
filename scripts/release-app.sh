#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"
version="${MCLASH_VERSION:-}"
bundle_version="${MCLASH_BUNDLE_VERSION:-${version%%[-+]*}}"
build_number="${MCLASH_BUILD_NUMBER:-}"
release_tag="${MCLASH_RELEASE_TAG:-v${version}}"
identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"
apple_id="${APPLE_ID:-}"
apple_password="${APPLE_APP_SPECIFIC_PASSWORD:-}"
apple_team_id="${APPLE_TEAM_ID:-}"
release_notes="${MCLASH_RELEASE_NOTES:-${repo_root}/ReleaseNotes/${version}.md}"
architecture="${MCLASH_ARCHITECTURE:-$(uname -m)}"
host_devid_profile="${MCLASH_HOST_DEVID_PROFILE_PATH:-}"
network_extension_devid_profile="${MCLASH_NETWORK_EXTENSION_DEVID_PROFILE_PATH:-}"
host_devid_entitlements="${MCLASH_HOST_DEVID_ENTITLEMENTS:-${repo_root}/Support/Signing/MClash-DeveloperID.entitlements}"
cli_devid_entitlements="${MCLASH_CLI_DEVID_ENTITLEMENTS:-${repo_root}/Support/Signing/MClashCLI-DeveloperID.entitlements}"
network_extension_devid_entitlements="${MCLASH_NETWORK_EXTENSION_DEVID_ENTITLEMENTS:-${repo_root}/Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements}"
host_bundle_id="one.leaper.mclash"
network_extension_bundle_id="one.leaper.mclash.network-extension"
application_identifier_prefix="${MCLASH_TEAM_IDENTIFIER_PREFIX:-${apple_team_id}}"
if [[ -n "${application_identifier_prefix}" && "${application_identifier_prefix}" != *. ]]; then
  application_identifier_prefix="${application_identifier_prefix}."
fi
signing_team_identifier="${apple_team_id:-${application_identifier_prefix%.}}"
host_application_identifier="${application_identifier_prefix}${host_bundle_id}"
extension_application_identifier="${application_identifier_prefix}${network_extension_bundle_id}"
host_keychain_group="${application_identifier_prefix}${host_bundle_id}.authorization"

if [[ -z "${version}" || -z "${build_number}" || -z "${identity}" ]]; then
  print -u2 "Set MCLASH_VERSION, MCLASH_BUILD_NUMBER, and CODE_SIGN_IDENTITY."
  exit 2
fi
if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "MCLASH_VERSION must be a semantic version: ${version}"
  exit 2
fi
if [[ ! "${bundle_version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "MCLASH_BUNDLE_VERSION must contain three dot-separated integers: ${bundle_version}"
  exit 2
fi
if [[ ! "${build_number}" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "MCLASH_BUILD_NUMBER must be a positive integer: ${build_number}"
  exit 2
fi
if [[ "${identity}" == "-" || "${identity}" != Developer\ ID\ Application:* ]]; then
  print -u2 "A Developer ID Application identity is required for a production release."
  exit 2
fi
for required_file in \
  "${host_devid_profile}" \
  "${network_extension_devid_profile}" \
  "${host_devid_entitlements}" \
  "${cli_devid_entitlements}" \
  "${network_extension_devid_entitlements}"
do
  if [[ -z "${required_file}" || ! -s "${required_file}" ]]; then
    print -u2 "Developer ID signing material is missing: ${required_file:-<unset>}"
    exit 2
  fi
done
if [[ "${architecture}" != "arm64" ]]; then
  print -u2 "The current release manifest only supports arm64, not ${architecture}."
  exit 2
fi
mihomo_alpha_select_architecture "${architecture}"
if [[ -z "${notary_profile}" && ( -z "${apple_id}" || -z "${apple_password}" || -z "${apple_team_id}" ) ]]; then
  print -u2 "Set NOTARYTOOL_PROFILE, or APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID."
  exit 2
fi
if [[ ! -s "${release_notes}" ]]; then
  print -u2 "Release notes are required: ${release_notes}"
  exit 1
fi
if [[ "${ALLOW_DIRTY_RELEASE:-0}" != "1" ]] && \
   [[ -n "$(DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" git -C "${repo_root}" status --porcelain --untracked-files=all)" ]]; then
  print -u2 "Production releases require a clean Git working tree."
  exit 1
fi

notarize() {
  local artifact="$1"
  if [[ -n "${notary_profile}" ]]; then
    xcrun notarytool submit "${artifact}" \
      --keychain-profile "${notary_profile}" \
      --wait \
      --timeout 30m
  else
    xcrun notarytool submit "${artifact}" \
      --apple-id "${apple_id}" \
      --password "${apple_password}" \
      --team-id "${apple_team_id}" \
      --wait \
      --timeout 30m
  fi
}

sign_path() {
  local target_path="$1"
  shift
  /usr/bin/codesign --force \
    --sign "${identity}" \
    --timestamp \
    --options runtime \
    "$@" \
    "${target_path}"
}

plist_array_contains() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local index=0
  local value

  while value="$(/usr/libexec/PlistBuddy -c "Print :${key}:${index}" "${plist}" 2>/dev/null)"; do
    if [[ "${value}" == "${expected}" ]]; then
      return 0
    fi
    (( index += 1 ))
  done
  return 1
}

verify_signed_entitlements() {
  local target_path="$1"
  local requires_system_extension_install="$2"
  local expected_application_identifier="$3"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/mclash-signed-entitlements.XXXXXX")"

  if ! /usr/bin/codesign -d --entitlements :- "${target_path}" > "${entitlements}" 2>/dev/null; then
    rm -f "${entitlements}"
    print -u2 "Could not read signed entitlements from ${target_path}."
    exit 1
  fi
  if ! plutil -lint "${entitlements}" >/dev/null; then
    rm -f "${entitlements}"
    print -u2 "Signed entitlements are not a valid plist: ${target_path}"
    exit 1
  fi
  if ! plist_array_contains \
    "${entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "app-proxy-provider-systemextension" || \
     ! plist_array_contains \
    "${entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "dns-proxy-systemextension"; then
    rm -f "${entitlements}"
    print -u2 "Signed Network Extension entitlements are incomplete: ${target_path}"
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${entitlements}" 2>/dev/null)" != "${expected_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${entitlements}" 2>/dev/null)" != "${signing_team_identifier}" ]]; then
    rm -f "${entitlements}"
    print -u2 "Signed identity does not match ${expected_application_identifier} / ${signing_team_identifier}: ${target_path}"
    exit 1
  fi
  if [[ "${requires_system_extension_install}" == "1" ]] && \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "${entitlements}" 2>/dev/null)" != "true" ]]; then
    rm -f "${entitlements}"
    print -u2 "The signed host is missing system-extension.install."
    exit 1
  fi
  rm -f "${entitlements}"
}

verify_keychain_identity() {
  local target_path="$1"
  local expected_application_identifier="$2"
  local expected_keychain_group="$3"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/mclash-keychain-entitlements.XXXXXX")"
  codesign -d --entitlements :- "${target_path}" > "${entitlements}" 2>/dev/null
  plutil -lint "${entitlements}" >/dev/null
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${entitlements}" 2>/dev/null)" != "${expected_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${entitlements}" 2>/dev/null)" != "${signing_team_identifier}" ]] || \
     ! plist_array_contains "${entitlements}" "keychain-access-groups" "${expected_keychain_group}"; then
    rm -f "${entitlements}"
    print -u2 "Signed Keychain identity is incomplete: ${target_path}"
    exit 1
  fi
  rm -f "${entitlements}"
}

verify_unrestricted_cli_entitlements() {
  local target_path="$1"
  local entitlements
  entitlements="$(mktemp "${TMPDIR:-/tmp}/mclash-cli-entitlements.XXXXXX")"
  codesign -d --entitlements :- "${target_path}" > "${entitlements}" 2>/dev/null
  plutil -lint "${entitlements}" >/dev/null
  for restricted_key in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    keychain-access-groups
  do
    if /usr/libexec/PlistBuddy -c "Print :${restricted_key}" "${entitlements}" >/dev/null 2>&1; then
      rm -f "${entitlements}"
      print -u2 "Signed automation CLI claims restricted entitlement ${restricted_key}."
      exit 1
    fi
  done
  rm -f "${entitlements}"
}

sign_application() {
  local app="$1"
  local sparkle="${app}/Contents/Frameworks/Sparkle.framework"
  local core="${app}/Contents/Resources/Core/${MIHOMO_ALPHA_BUNDLE_NAME}"
  local automation_cli="${app}/Contents/Helpers/mclashctl"
  local system_extension="${app}/Contents/Library/SystemExtensions/${network_extension_bundle_id}.systemextension"

  if [[ -d "${sparkle}" ]]; then
    local version_root="${sparkle}/Versions/B"
    for helper in \
      "${version_root}/XPCServices/Installer.xpc" \
      "${version_root}/XPCServices/Downloader.xpc" \
      "${version_root}/Autoupdate" \
      "${version_root}/Updater.app"
    do
      if [[ ! -e "${helper}" ]]; then
        print -u2 "Sparkle is missing a required signed component: ${helper}"
        exit 1
      fi
      if [[ "${helper:t}" == "Downloader.xpc" ]]; then
        sign_path "${helper}" --preserve-metadata=entitlements
      else
        sign_path "${helper}"
      fi
    done
    sign_path "${sparkle}"
  fi

  if [[ ! -f "${core}" ]]; then
    print -u2 "Bundled core is missing: ${core}"
    exit 1
  fi
  if [[ ! -x "${automation_cli}" ]]; then
    print -u2 "Bundled automation CLI is missing: ${automation_cli}"
    exit 1
  fi
  if [[ ! -d "${system_extension}" ]]; then
    print -u2 "Bundled Network Extension is missing: ${system_extension}"
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${system_extension}/Contents/Info.plist")" != "${network_extension_bundle_id}" ]]; then
    print -u2 "Bundled Network Extension has an unexpected bundle identifier."
    exit 1
  fi

  cp "${host_devid_profile}" "${app}/Contents/embedded.provisionprofile"
  cp "${network_extension_devid_profile}" "${system_extension}/Contents/embedded.provisionprofile"
  chmod 600 \
    "${app}/Contents/embedded.provisionprofile" \
    "${system_extension}/Contents/embedded.provisionprofile"

  sign_path "${automation_cli}" --entitlements "${cli_devid_entitlements}"
  sign_path "${core}"
  sign_path "${system_extension}" --entitlements "${network_extension_devid_entitlements}"
  sign_path "${app}" --entitlements "${host_devid_entitlements}"

  if ! cmp -s "${host_devid_profile}" "${app}/Contents/embedded.provisionprofile" || \
     ! cmp -s "${network_extension_devid_profile}" "${system_extension}/Contents/embedded.provisionprofile"; then
    print -u2 "Embedded provisioning profiles do not match the validated release profiles."
    exit 1
  fi
  verify_signed_entitlements "${system_extension}" 0 "${extension_application_identifier}"
  verify_signed_entitlements "${app}" 1 "${host_application_identifier}"
  verify_keychain_identity "${app}" "${host_application_identifier}" "${host_keychain_group}"
  verify_unrestricted_cli_entitlements "${automation_cli}"
}

export CONFIGURATION=release
export MCLASH_VERSION="${version}"
export MCLASH_BUNDLE_VERSION="${bundle_version}"
export MCLASH_BUILD_NUMBER="${build_number}"
export CODE_SIGN_IDENTITY="${identity}"
"${repo_root}/scripts/build-app.sh"

app="${repo_root}/.build/release/MClash.app"
if [[ ! -d "${app}" ]]; then
  print -u2 "Release build did not produce ${app}."
  exit 1
fi

# Sparkle's BinaryDelta rejects legacy code-signing xattrs. Clear the fresh
# build before signing so the released target is a deterministic delta input.
xattr -cr "${app}"
sign_application "${app}"
system_extension="${app}/Contents/Library/SystemExtensions/${network_extension_bundle_id}.systemextension"
codesign --verify --strict --verbose=2 "${system_extension}"
codesign --verify --deep --strict --verbose=2 "${app}"

app_architectures="$(lipo -archs "${app}/Contents/MacOS/MClash")"
if [[ " ${app_architectures} " != *" arm64 "* ]]; then
  print -u2 "Release binary is not arm64: ${app_architectures}"
  exit 1
fi
extension_architectures="$(lipo -archs "${system_extension}/Contents/MacOS/MClashNetworkExtension")"
if [[ " ${extension_architectures} " != *" arm64 "* ]]; then
  print -u2 "Release Network Extension binary is not arm64: ${extension_architectures}"
  exit 1
fi

release_dir="${repo_root}/.build/releases/${version}-${build_number}"
mkdir -p "${release_dir}"
notary_submission="${release_dir}/MClash-${version}-notary-submission.zip"
update_zip="${release_dir}/MClash-${version}-macos-arm64.zip"
dmg="${release_dir}/MClash-${version}-macos-arm64.dmg"
appcast="${release_dir}/appcast.xml"
checksums="${release_dir}/SHA256SUMS"
delta_manifest="${release_dir}/delta-manifest.json"
mihomo_source="${release_dir}/mihomo-${MIHOMO_ALPHA_REVISION}-source.tar.gz"
sparkle_license="${release_dir}/Sparkle-2.9.4-LICENSE.txt"

ditto -c -k --sequesterRsrc --keepParent "${app}" "${notary_submission}"
notarize "${notary_submission}"
xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
spctl --assess --type execute --verbose=2 "${app}"

# The update ZIP is made after stapling so Sparkle installs a self-contained,
# offline-verifiable app bundle.
ditto -c -k --sequesterRsrc --keepParent "${app}" "${update_zip}"
"${repo_root}/scripts/create-dmg.sh" "${app}" "${dmg}" "MClash ${version}"
sign_path "${dmg}"
notarize "${dmg}"
xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"
codesign --verify --strict --verbose=2 "${dmg}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg}"

export MCLASH_RELEASE_TAG="${release_tag}"
"${repo_root}/scripts/generate-delta-updates.sh" \
  "${app}" \
  "${update_zip}" \
  "${release_dir}" \
  "${delta_manifest}"
"${repo_root}/scripts/generate-appcast.sh" \
  "${update_zip}" \
  "${appcast}" \
  "${release_notes}" \
  "${delta_manifest}"
"${repo_root}/scripts/package-mihomo-source.sh" "${mihomo_source}"
sparkle_tools="$(${repo_root}/scripts/fetch-sparkle-tools.sh)"
cp "${sparkle_tools}/LICENSE" "${sparkle_license}"

(
  cd "${release_dir}"
  checksum_assets=(
    "${dmg:t}" \
    "${update_zip:t}" \
    "${appcast:t}" \
    "${mihomo_source:t}" \
    "${sparkle_license:t}"
  )
  for delta in MClash-${version}-from-*-macos-arm64.delta(N); do
    checksum_assets+=("${delta}")
  done
  shasum -a 256 "${checksum_assets[@]}" > "${checksums:t}"
)

print "Release assets ready in ${release_dir}:"
print "  ${dmg:t}"
print "  ${update_zip:t}"
print "  ${appcast:t}"
print "  ${mihomo_source:t}"
print "  ${sparkle_license:t}"
for delta in "${release_dir}"/MClash-${version}-from-*-macos-arm64.delta(N); do
  print "  ${delta:t}"
done
print "  ${checksums:t}"
