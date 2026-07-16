#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
version="${MCLASH_VERSION:-}"
build_number="${MCLASH_BUILD_NUMBER:-}"
identity="${CODE_SIGN_IDENTITY:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"

if [[ -z "${version}" || -z "${build_number}" || -z "${identity}" || -z "${notary_profile}" ]]; then
  print -u2 "Set MCLASH_VERSION, MCLASH_BUILD_NUMBER, CODE_SIGN_IDENTITY, and NOTARYTOOL_PROFILE."
  exit 2
fi
if [[ "${identity}" == "-" ]]; then
  print -u2 "A Developer ID Application identity is required for a production release."
  exit 2
fi
if [[ -n "$(git -C "${repo_root}" status --porcelain --untracked-files=all)" ]]; then
  print -u2 "Production releases require a clean Git working tree."
  exit 1
fi

export CONFIGURATION=release
"${repo_root}/scripts/build-app.sh"

app="${repo_root}/.build/release/MClash.app"
release_dir="${repo_root}/.build/releases"
architecture="$(uname -m)"
submission_zip="${release_dir}/MClash-${version}-macos-${architecture}-notary-submission.zip"
release_zip="${release_dir}/MClash-${version}-macos-${architecture}.zip"
mkdir -p "${release_dir}"
rm -f "${submission_zip}" "${release_zip}"

ditto -c -k --keepParent "${app}" "${submission_zip}"
xcrun notarytool submit "${submission_zip}" \
  --keychain-profile "${notary_profile}" \
  --wait
xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
spctl --assess --type execute --verbose=2 "${app}"

ditto -c -k --keepParent "${app}" "${release_zip}"
(cd "${release_dir}" && shasum -a 256 "${release_zip:t}" > "${release_zip:t}.sha256")
rm -f "${submission_zip}"

print "Release ready: ${release_zip}"
