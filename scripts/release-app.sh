#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"
version="${MCLASH_VERSION:-}"
build_number="${MCLASH_BUILD_NUMBER:-}"
release_tag="${MCLASH_RELEASE_TAG:-v${version}}"
identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"
apple_id="${APPLE_ID:-}"
apple_password="${APPLE_APP_SPECIFIC_PASSWORD:-}"
apple_team_id="${APPLE_TEAM_ID:-}"
release_notes="${MCLASH_RELEASE_NOTES:-${repo_root}/ReleaseNotes/${version}.md}"
architecture="${MCLASH_ARCHITECTURE:-$(uname -m)}"

if [[ -z "${version}" || -z "${build_number}" || -z "${identity}" ]]; then
  print -u2 "Set MCLASH_VERSION, MCLASH_BUILD_NUMBER, and CODE_SIGN_IDENTITY."
  exit 2
fi
if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "MCLASH_VERSION must be a semantic version: ${version}"
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

sign_application() {
  local app="$1"
  local sparkle="${app}/Contents/Frameworks/Sparkle.framework"
  local core="${app}/Contents/Resources/Core/${MIHOMO_ALPHA_RESOURCE_NAME}"

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
  sign_path "${core}"
  sign_path "${app}"
}

export CONFIGURATION=release
export MCLASH_VERSION="${version}"
export MCLASH_BUILD_NUMBER="${build_number}"
export CODE_SIGN_IDENTITY="${identity}"
"${repo_root}/scripts/build-app.sh"

app="${repo_root}/.build/release/MClash.app"
if [[ ! -d "${app}" ]]; then
  print -u2 "Release build did not produce ${app}."
  exit 1
fi

sign_application "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"

app_architectures="$(lipo -archs "${app}/Contents/MacOS/MClash")"
if [[ " ${app_architectures} " != *" arm64 "* ]]; then
  print -u2 "Release binary is not arm64: ${app_architectures}"
  exit 1
fi

release_dir="${repo_root}/.build/releases/${version}-${build_number}"
mkdir -p "${release_dir}"
notary_submission="${release_dir}/MClash-${version}-notary-submission.zip"
update_zip="${release_dir}/MClash-${version}-macos-arm64.zip"
dmg="${release_dir}/MClash-${version}-macos-arm64.dmg"
appcast="${release_dir}/appcast.xml"
checksums="${release_dir}/SHA256SUMS"
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
"${repo_root}/scripts/generate-appcast.sh" \
  "${update_zip}" \
  "${appcast}" \
  "${release_notes}"
"${repo_root}/scripts/package-mihomo-source.sh" "${mihomo_source}"
sparkle_tools="$(${repo_root}/scripts/fetch-sparkle-tools.sh)"
cp "${sparkle_tools}/LICENSE" "${sparkle_license}"

(
  cd "${release_dir}"
  shasum -a 256 \
    "${dmg:t}" \
    "${update_zip:t}" \
    "${appcast:t}" \
    "${mihomo_source:t}" \
    "${sparkle_license:t}" > "${checksums:t}"
)

print "Release assets ready in ${release_dir}:"
print "  ${dmg:t}"
print "  ${update_zip:t}"
print "  ${appcast:t}"
print "  ${mihomo_source:t}"
print "  ${sparkle_license:t}"
print "  ${checksums:t}"
