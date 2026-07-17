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

if [[ ! -d "${sparkle_framework}" ]]; then
  print -u2 "Sparkle.framework was not found at ${sparkle_framework}."
  exit 1
fi

mihomo_alpha_select_architecture "${architecture}"

if [[ ! -f "${MIHOMO_ALPHA_RESOURCE_PATH}" ]]; then
  "${repo_root}/scripts/fetch-mihomo-alpha.sh" --architecture "${architecture}"
fi
mihomo_alpha_verify_selected_artifact

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

"${repo_root}/scripts/typecheck.sh"

application_sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
binary_output="${build_root}/MClash"
mkdir -p "${build_root}"
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
  -framework Sparkle \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -Xlinker -rpath \
  -Xlinker @executable_path/../Frameworks \
  "${application_sources[@]}" \
  -o "${binary_output}"

rm -rf "${app_bundle}"
mkdir -p "${contents}/MacOS" "${contents}/Frameworks" "${contents}/Resources/Core" "${contents}/Resources/ThirdParty"
cp "${binary_output}" "${contents}/MacOS/MClash"
ditto "${sparkle_framework}" "${contents}/Frameworks/Sparkle.framework"
cp "${repo_root}/Support/Info.plist" "${contents}/Info.plist"
cp "${MIHOMO_ALPHA_RESOURCE_PATH}" "${contents}/Resources/Core/${MIHOMO_ALPHA_RESOURCE_NAME}"
cp "${repo_root}/Sources/MClashApp/Resources/AppIcon.icns" "${contents}/Resources/AppIcon.icns"
cp "${mclash_license}" "${contents}/Resources/MClash-LICENSE.txt"
cp "${license_source}" "${contents}/Resources/ThirdParty/mihomo-LICENSE.txt"
cp "${corresponding_source}" "${contents}/Resources/ThirdParty/mihomo-SOURCE.txt"
cp "${notice_source}" "${contents}/Resources/ThirdParty/mihomo-NOTICE.md"
cp "${sparkle_framework_dir}/LICENSE" "${contents}/Resources/ThirdParty/Sparkle-LICENSE.txt"
recorded_hash="$(mihomo_alpha_recorded_hash "${MIHOMO_ALPHA_RESOURCE_NAME}")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${app_version}" \
  -c "Set :CFBundleVersion ${build_number}" \
  "${contents}/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Add :MClashMihomoAlphaVersion string ${MIHOMO_ALPHA_VERSION}" \
  -c "Add :MClashMihomoAlphaRawSHA256 string ${recorded_hash}" \
  -c "Add :MClashSourceRevision string ${source_revision}" \
  "${contents}/Info.plist"

packaged_hash="$(shasum -a 256 "${contents}/Resources/Core/${MIHOMO_ALPHA_RESOURCE_NAME}" | awk '{ print $1 }')"
if [[ "${packaged_hash}" != "${recorded_hash}" ]]; then
  print -u2 "Packaged mihomo Alpha SHA-256 changed while assembling the app"
  exit 1
fi

packaged_core="${contents}/Resources/Core/${MIHOMO_ALPHA_RESOURCE_NAME}"
if [[ "${code_sign_identity}" == "-" ]]; then
  codesign --force --sign - "${packaged_core}"
  codesign --force --sign - "${app_bundle}"
else
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
    --sign "${code_sign_identity}" "${packaged_core}"
  codesign --force --options runtime --timestamp \
    --sign "${code_sign_identity}" "${app_bundle}"
fi
codesign --verify --strict --verbose=2 "${packaged_core}"
codesign --verify --deep --strict --verbose=2 "${app_bundle}"
print "Built MClash ${app_version} (${build_number}) at ${app_bundle} with mihomo ${MIHOMO_ALPHA_VERSION} (${packaged_hash})"
