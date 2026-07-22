#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"

configuration="${CONFIGURATION:-release}"
app_version="${MCLASH_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${repo_root}/Support/Info.plist")}"
build_number="${MCLASH_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${repo_root}/Support/Info.plist")}"
code_sign_identity="${CODE_SIGN_IDENTITY:--}"
build_root="${repo_root}/.build/${configuration}"
app_bundle="${build_root}/MClash.app"
contents="${app_bundle}/Contents"
architecture="$(uname -m)"
source_revision="$(git -C "${repo_root}" rev-parse HEAD)"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:-$(${repo_root}/scripts/fetch-sparkle-tools.sh)}"
sparkle_framework="${sparkle_framework_dir}/Sparkle.framework"
host_devid_profile="${MCLASH_HOST_DEVID_PROFILE_PATH:-}"
network_extension_devid_profile="${MCLASH_NETWORK_EXTENSION_DEVID_PROFILE_PATH:-}"
host_devid_entitlements="${MCLASH_HOST_DEVID_ENTITLEMENTS:-${repo_root}/Support/Signing/MClash-DeveloperID.entitlements}"
cli_devid_entitlements="${MCLASH_CLI_DEVID_ENTITLEMENTS:-${repo_root}/Support/Signing/MClashCLI-DeveloperID.entitlements}"
network_extension_devid_entitlements="${MCLASH_NETWORK_EXTENSION_DEVID_ENTITLEMENTS:-${repo_root}/Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements}"
host_bundle_id="one.leaper.mclash"
network_extension_bundle_id="one.leaper.mclash.network-extension"
system_extension="${contents}/Library/SystemExtensions/${network_extension_bundle_id}.systemextension"
system_extension_contents="${system_extension}/Contents"
network_extension_info_source="${repo_root}/Support/NetworkExtension/Info.plist"
login_agent_source="${repo_root}/Support/LaunchAgents/one.leaper.mclash.login.plist"
team_identifier_prefix="${MCLASH_TEAM_IDENTIFIER_PREFIX:-${APPLE_TEAM_ID:-}}"
if [[ -n "${team_identifier_prefix}" && "${team_identifier_prefix}" != *. ]]; then
  team_identifier_prefix="${team_identifier_prefix}."
fi
team_identifier="${APPLE_TEAM_ID:-${team_identifier_prefix%.}}"
host_application_identifier="${team_identifier_prefix}${host_bundle_id}"
extension_application_identifier="${team_identifier_prefix}${network_extension_bundle_id}"
app_group_identifier="${host_application_identifier}"
host_keychain_group="${team_identifier_prefix}${host_bundle_id}.authorization"

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

if [[ ! -d "${sparkle_framework}" ]]; then
  print -u2 "Sparkle.framework was not found at ${sparkle_framework}."
  exit 1
fi

mihomo_alpha_select_architecture "${architecture}"

if [[ ! -f "${MIHOMO_ALPHA_RESOURCE_PATH}" ]]; then
  "${repo_root}/scripts/fetch-mihomo-alpha.sh" --architecture "${architecture}"
fi
mihomo_alpha_verify_selected_artifact

geodata_source="${MCLASH_GEODATA_DIR:-${build_root}/GeoData}"
geodata_fetch_arguments=(--output "${geodata_source}")
if [[ "${code_sign_identity}" != "-" || "${MCLASH_REFRESH_GEODATA:-0}" == "1" ]]; then
  geodata_fetch_arguments+=(--refresh)
fi
"${repo_root}/scripts/fetch-mihomo-geodata.sh" "${geodata_fetch_arguments[@]}"
"${repo_root}/scripts/smoke-test-mihomo-geodata.sh" \
  "${MIHOMO_ALPHA_RESOURCE_PATH}" \
  "${geodata_source}"

license_source="${repo_root}/Sources/MClashApp/Resources/ThirdParty/mihomo-LICENSE.txt"
corresponding_source="${repo_root}/Sources/MClashApp/Resources/ThirdParty/mihomo-SOURCE.txt"
notice_source="${repo_root}/ThirdParty/mihomo/NOTICE.md"
mclash_license="${repo_root}/LICENSE"
for required_file in "${mclash_license}" "${license_source}" "${corresponding_source}" "${notice_source}"; do
  if [[ ! -s "${required_file}" ]]; then
    print -u2 "Missing required mihomo distribution material: ${required_file}"
    exit 1
  fi
done
if ! grep -Fq "${MIHOMO_ALPHA_REVISION}" "${corresponding_source}"; then
  print -u2 "mihomo-SOURCE.txt does not reference the pinned revision ${MIHOMO_ALPHA_REVISION}."
  exit 1
fi

application_sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
automation_sources=("${repo_root}"/Sources/MClashAutomationProtocol/**/*.swift(N))
cli_sources=("${repo_root}"/Sources/MClashCLI/**/*.swift(N))
binary_output="${build_root}/MClash"
automation_library="${build_root}/libMClashAutomationProtocol.a"
cli_binary_output="${build_root}/mclashctl"
network_shared_sources=("${repo_root}"/Sources/MClashNetworkShared/**/*.swift(N))
network_extension_sources=("${repo_root}"/Sources/MClashNetworkExtension/**/*.swift(N))
network_shared_library="${build_root}/libMClashNetworkShared.a"
network_extension_binary_output="${build_root}/MClashNetworkExtension"
if (( ${#network_extension_sources[@]} == 0 )); then
  print -u2 "Network Extension sources are missing."
  exit 1
fi
if [[ ! -s "${network_extension_info_source}" ]]; then
  print -u2 "Network Extension Info.plist is missing: ${network_extension_info_source}"
  exit 1
fi
mkdir -p "${build_root}"
swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -whole-module-optimization \
  -target "${architecture}-apple-macosx14.0" \
  -emit-module \
  -emit-library \
  -static \
  -module-name MClashAutomationProtocol \
  -framework Security \
  "${automation_sources[@]}" \
  -emit-module-path "${build_root}/MClashAutomationProtocol.swiftmodule" \
  -o "${automation_library}"
swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -whole-module-optimization \
  -target "${architecture}-apple-macosx14.0" \
  -emit-module \
  -emit-library \
  -static \
  -module-name MClashNetworkShared \
  "${network_shared_sources[@]}" \
  -emit-module-path "${build_root}/MClashNetworkShared.swiftmodule" \
  -o "${network_shared_library}"
swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -whole-module-optimization \
  -target "$(uname -m)-apple-macosx14.0" \
  -F "${sparkle_framework_dir}" \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework NetworkExtension \
  -framework SystemExtensions \
  -framework Sparkle \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -lsqlite3 \
  -I "${build_root}" \
  -L "${build_root}" \
  -lMClashNetworkShared \
  -lMClashAutomationProtocol \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${application_sources[@]}" \
  -o "${binary_output}"
swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -whole-module-optimization \
  -target "${architecture}-apple-macosx14.0" \
  -framework AppKit \
  -framework Security \
  -I "${build_root}" \
  -L "${build_root}" \
  -lMClashAutomationProtocol \
  "${cli_sources[@]}" \
  -o "${cli_binary_output}"
swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -O \
  -whole-module-optimization \
  -target "${architecture}-apple-macosx14.0" \
  -module-name MClashNetworkExtension \
  -framework Network \
  -framework NetworkExtension \
  -framework Security \
  -lbsm \
  -I "${build_root}" \
  -L "${build_root}" \
  -lMClashNetworkShared \
  "${network_extension_sources[@]}" \
  -o "${network_extension_binary_output}"

rm -rf "${app_bundle}"
mkdir -p \
  "${contents}/MacOS" \
  "${contents}/Helpers" \
  "${contents}/Frameworks" \
  "${contents}/Library/LaunchAgents" \
  "${contents}/Resources/Core" \
  "${contents}/Resources/GeoData" \
  "${contents}/Resources/ThirdParty" \
  "${system_extension_contents}/MacOS"
cp "${binary_output}" "${contents}/MacOS/MClash"
cp "${cli_binary_output}" "${contents}/Helpers/mclashctl"
cp "${network_extension_binary_output}" "${system_extension_contents}/MacOS/MClashNetworkExtension"
ditto "${sparkle_framework}" "${contents}/Frameworks/Sparkle.framework"
cp "${repo_root}/Support/Info.plist" "${contents}/Info.plist"
cp "${network_extension_info_source}" "${system_extension_contents}/Info.plist"
cp "${login_agent_source}" "${contents}/Library/LaunchAgents/one.leaper.mclash.login.plist"
plutil -lint "${contents}/Library/LaunchAgents/one.leaper.mclash.login.plist" >/dev/null
cp "${MIHOMO_ALPHA_RESOURCE_PATH}" "${contents}/Resources/Core/${MIHOMO_ALPHA_BUNDLE_NAME}"
ditto "${geodata_source}" "${contents}/Resources/GeoData"
cp "${license_source}" "${contents}/Resources/GeoData/LICENSE.txt"
cp "${repo_root}/Sources/MClashApp/Resources/AppIcon.icns" "${contents}/Resources/AppIcon.icns"
for localization_source in "${repo_root}"/Sources/MClashApp/Resources/*.lproj(N/); do
  ditto "${localization_source}" "${contents}/Resources/${localization_source:t}"
done
cp "${mclash_license}" "${contents}/Resources/MClash-LICENSE.txt"
cp "${license_source}" "${contents}/Resources/ThirdParty/mihomo-LICENSE.txt"
cp "${corresponding_source}" "${contents}/Resources/ThirdParty/mihomo-SOURCE.txt"
cp "${notice_source}" "${contents}/Resources/ThirdParty/mihomo-NOTICE.md"
cp "${sparkle_framework_dir}/LICENSE" "${contents}/Resources/ThirdParty/Sparkle-LICENSE.txt"
"${repo_root}/scripts/verify-mihomo-geodata.sh" "${contents}/Resources/GeoData"
recorded_hash="$(mihomo_alpha_recorded_hash "${MIHOMO_ALPHA_RESOURCE_NAME}")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${app_version}" \
  -c "Set :CFBundleVersion ${build_number}" \
  "${contents}/Info.plist"
if /usr/libexec/PlistBuddy -c 'Print :NSSystemExtensionUsageDescription' "${contents}/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c \
    'Set :NSSystemExtensionUsageDescription MClash uses a network system extension to apply per-application proxy and DNS routing rules.' \
    "${contents}/Info.plist"
else
  /usr/libexec/PlistBuddy -c \
    'Add :NSSystemExtensionUsageDescription string MClash uses a network system extension to apply per-application proxy and DNS routing rules.' \
    "${contents}/Info.plist"
fi
/usr/libexec/PlistBuddy -c \
  "Add :MClashMihomoAlphaVersion string ${MIHOMO_ALPHA_VERSION}" \
  -c "Add :MClashMihomoAlphaRawSHA256 string ${recorded_hash}" \
  -c "Add :MClashSourceRevision string ${source_revision}" \
  "${contents}/Info.plist"
/usr/libexec/PlistBuddy \
  -c 'Set :CFBundleExecutable MClashNetworkExtension' \
  -c "Set :CFBundleShortVersionString ${app_version}" \
  -c "Set :CFBundleVersion ${build_number}" \
  -c "Set :NetworkExtension:NEMachServiceName ${app_group_identifier}.network-extension" \
  "${system_extension_contents}/Info.plist"
plutil -lint "${system_extension_contents}/Info.plist" >/dev/null
if grep -Eq '\$\([^)]+\)' "${system_extension_contents}/Info.plist"; then
  print -u2 "Unresolved build-setting placeholder in Network Extension Info.plist."
  exit 1
fi

packaged_hash="$(shasum -a 256 "${contents}/Resources/Core/${MIHOMO_ALPHA_BUNDLE_NAME}" | awk '{ print $1 }')"
if [[ "${packaged_hash}" != "${recorded_hash}" ]]; then
  print -u2 "Packaged mihomo Alpha SHA-256 changed while assembling the app"
  exit 1
fi

packaged_core="${contents}/Resources/Core/${MIHOMO_ALPHA_BUNDLE_NAME}"
if [[ "${code_sign_identity}" == "-" ]]; then
  codesign --force --sign - "${contents}/Helpers/mclashctl"
  codesign --force --sign - "${packaged_core}"
  codesign --force \
    --entitlements "${network_extension_devid_entitlements}" \
    --sign - "${system_extension}"
  codesign --force \
    --entitlements "${host_devid_entitlements}" \
    --sign - "${app_bundle}"
else
  for required_file in \
    "${host_devid_profile}" \
    "${network_extension_devid_profile}" \
    "${host_devid_entitlements}" \
    "${cli_devid_entitlements}" \
    "${network_extension_devid_entitlements}"
  do
    if [[ -z "${required_file}" || ! -s "${required_file}" ]]; then
      print -u2 "Developer ID signing material is missing: ${required_file:-<unset>}"
      exit 1
    fi
  done
  if [[ ! -d "${system_extension}" ]]; then
    print -u2 "The Network Extension system extension is missing: ${system_extension}"
    exit 1
  fi
  if [[ -z "${team_identifier_prefix}" ]]; then
    print -u2 "MCLASH_TEAM_IDENTIFIER_PREFIX or APPLE_TEAM_ID is required for Developer ID builds."
    exit 1
  fi
  if [[ -z "${team_identifier}" ]]; then
    print -u2 "APPLE_TEAM_ID or MCLASH_TEAM_IDENTIFIER_PREFIX is required to verify Developer ID identities."
    exit 1
  fi
  extension_info="${system_extension}/Contents/Info.plist"
  if [[ ! -s "${extension_info}" ]]; then
    print -u2 "The Network Extension Info.plist is missing: ${extension_info}"
    exit 1
  fi
  actual_extension_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${extension_info}")"
  if [[ "${actual_extension_bundle_id}" != "${network_extension_bundle_id}" ]]; then
    print -u2 "Unexpected Network Extension bundle identifier: ${actual_extension_bundle_id}"
    exit 1
  fi
  if ! plist_array_contains \
    "${host_devid_entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "app-proxy-provider-systemextension" || \
     ! plist_array_contains \
    "${host_devid_entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "dns-proxy-systemextension"; then
    print -u2 "Host entitlements must authorize both Network Extension provider types."
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "${host_devid_entitlements}" 2>/dev/null)" != "true" ]]; then
    print -u2 "Host entitlements must authorize system extension installation."
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${host_devid_entitlements}" 2>/dev/null)" != "${host_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${host_devid_entitlements}" 2>/dev/null)" != "${team_identifier}" ]]; then
    print -u2 "Host entitlements must declare ${host_application_identifier} for Apple team ${team_identifier}."
    exit 1
  fi
  if ! plist_array_contains \
    "${network_extension_devid_entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "app-proxy-provider-systemextension" || \
     ! plist_array_contains \
    "${network_extension_devid_entitlements}" \
    "com.apple.developer.networking.networkextension" \
    "dns-proxy-systemextension"; then
    print -u2 "Network Extension entitlements must authorize both provider types."
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${network_extension_devid_entitlements}" 2>/dev/null)" != "${extension_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${network_extension_devid_entitlements}" 2>/dev/null)" != "${team_identifier}" ]]; then
    print -u2 "Network Extension entitlements must declare ${extension_application_identifier} for Apple team ${team_identifier}."
    exit 1
  fi
  for entitlement_file in \
    "${host_devid_entitlements}" \
    "${network_extension_devid_entitlements}"
  do
    if ! plist_array_contains \
      "${entitlement_file}" \
      "com.apple.security.application-groups" \
      "${app_group_identifier}"; then
      print -u2 "${entitlement_file:t} must claim macOS App Group ${app_group_identifier}."
      exit 1
    fi
  done
  expected_mach_service="${app_group_identifier}.network-extension"
  actual_mach_service="$(/usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEMachServiceName' "${extension_info}")"
  if [[ "${actual_mach_service}" != "${expected_mach_service}" ]]; then
    print -u2 "Network Extension Mach service ${actual_mach_service} must be a child of App Group ${app_group_identifier}."
    exit 1
  fi

  cp "${host_devid_profile}" "${contents}/embedded.provisionprofile"
  cp "${network_extension_devid_profile}" "${system_extension}/Contents/embedded.provisionprofile"
  chmod 600 \
    "${contents}/embedded.provisionprofile" \
    "${system_extension}/Contents/embedded.provisionprofile"

  sparkle_version_root="${contents}/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${sparkle_version_root}/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements \
    --sign "${code_sign_identity}" "${sparkle_version_root}/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${sparkle_version_root}/Autoupdate"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${sparkle_version_root}/Updater.app"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${contents}/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp \
    --entitlements "${cli_devid_entitlements}" \
    --sign "${code_sign_identity}" "${contents}/Helpers/mclashctl"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${packaged_core}"
  codesign --force --options runtime --timestamp \
    --entitlements "${network_extension_devid_entitlements}" \
    --sign "${code_sign_identity}" "${system_extension}"
  codesign --force --options runtime --timestamp \
    --entitlements "${host_devid_entitlements}" \
    --sign "${code_sign_identity}" "${app_bundle}"
fi
codesign --verify --strict --verbose=2 "${packaged_core}"
codesign --verify --strict --verbose=2 "${contents}/Helpers/mclashctl"
if [[ -d "${system_extension}" ]]; then
  codesign --verify --strict --verbose=2 "${system_extension}"
fi
codesign --verify --deep --strict --verbose=2 "${app_bundle}"
if [[ "${code_sign_identity}" != "-" ]]; then
  signed_host_entitlements="${build_root}/MClash.signed-entitlements.plist"
  signed_cli_entitlements="${build_root}/mclashctl.signed-entitlements.plist"
  signed_extension_entitlements="${build_root}/MClashNetworkExtension.signed-entitlements.plist"
  codesign -d --entitlements :- "${app_bundle}" > "${signed_host_entitlements}" 2>/dev/null
  codesign -d --entitlements :- "${contents}/Helpers/mclashctl" > "${signed_cli_entitlements}" 2>/dev/null
  codesign -d --entitlements :- "${system_extension}" > "${signed_extension_entitlements}" 2>/dev/null
  for signed_entitlements in \
    "${signed_host_entitlements}" \
    "${signed_extension_entitlements}"
  do
    plutil -lint "${signed_entitlements}" >/dev/null
    if ! plist_array_contains \
      "${signed_entitlements}" \
      "com.apple.security.application-groups" \
      "${app_group_identifier}"; then
      print -u2 "Signed code is missing macOS App Group ${app_group_identifier}: ${signed_entitlements:t}"
      exit 1
    fi
  done
  plutil -lint "${signed_cli_entitlements}" >/dev/null
  if ! plist_array_contains "${signed_host_entitlements}" "keychain-access-groups" "${host_keychain_group}"; then
    print -u2 "Signed host is missing Keychain group ${host_keychain_group}."
    exit 1
  fi
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${signed_host_entitlements}" 2>/dev/null)" != "${host_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${signed_host_entitlements}" 2>/dev/null)" != "${team_identifier}" ]]; then
    print -u2 "Signed host identity does not match ${host_application_identifier} / ${team_identifier}."
    exit 1
  fi
  for restricted_key in \
    com.apple.application-identifier \
    com.apple.developer.team-identifier \
    keychain-access-groups
  do
    if /usr/libexec/PlistBuddy -c "Print :${restricted_key}" "${signed_cli_entitlements}" >/dev/null 2>&1; then
      print -u2 "Signed mclashctl must not claim restricted entitlement ${restricted_key}."
      exit 1
    fi
  done
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "${signed_extension_entitlements}" 2>/dev/null)" != "${extension_application_identifier}" ]] || \
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "${signed_extension_entitlements}" 2>/dev/null)" != "${team_identifier}" ]]; then
    print -u2 "Signed Network Extension identity does not match ${extension_application_identifier} / ${team_identifier}."
    exit 1
  fi
fi
print "Built MClash ${app_version} (${build_number}) at ${app_bundle} with mihomo ${MIHOMO_ALPHA_VERSION} (${packaged_hash})"
