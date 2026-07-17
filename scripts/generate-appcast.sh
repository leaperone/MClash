#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
archive="${1:-}"
output="${2:-}"
release_notes="${3:-}"
repository="${GITHUB_REPOSITORY:-leaperone/MClash}"
tag="${MCLASH_RELEASE_TAG:-}"
build_number="${MCLASH_BUILD_NUMBER:-}"
private_key="${SPARKLE_PRIVATE_KEY:-}"

if [[ -z "${archive}" || -z "${output}" || -z "${tag}" || -z "${build_number}" || -z "${private_key}" ]]; then
  print -u2 "Usage: generate-appcast.sh UPDATE_ARCHIVE OUTPUT_APPCAST [RELEASE_NOTES]"
  print -u2 "Set MCLASH_RELEASE_TAG, MCLASH_BUILD_NUMBER, and SPARKLE_PRIVATE_KEY."
  exit 2
fi
if [[ ! -f "${archive}" ]]; then
  print -u2 "Update archive does not exist: ${archive}"
  exit 1
fi
if [[ -n "${release_notes}" && ! -f "${release_notes}" ]]; then
  print -u2 "Release notes do not exist: ${release_notes}"
  exit 1
fi

sparkle_tools="$(${repo_root}/scripts/fetch-sparkle-tools.sh)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-appcast.XXXXXX")"
archive_name="${archive:t}"
cp "${archive}" "${work_dir}/${archive_name}"
if [[ -n "${release_notes}" ]]; then
  cp "${release_notes}" "${work_dir}/${archive_name:r}.md"
fi

download_prefix="https://github.com/${repository}/releases/download/${tag}/"
printf '%s' "${private_key}" | \
  "${sparkle_tools}/bin/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "${download_prefix}" \
    --link "https://github.com/${repository}" \
    --versions "${build_number}" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --embed-release-notes \
    --disable-signing-warning \
    -o "${work_dir}/appcast.xml" \
    "${work_dir}"

generated="${work_dir}/appcast.xml"
if [[ ! -s "${generated}" ]]; then
  print -u2 "Sparkle did not generate an appcast."
  exit 1
fi
if ! grep -Fq 'sparkle:edSignature=' "${generated}"; then
  print -u2 "Generated appcast does not contain an EdDSA update signature."
  exit 1
fi
if ! grep -Fq "${download_prefix}${archive_name}" "${generated}"; then
  print -u2 "Generated appcast does not reference the immutable release URL."
  exit 1
fi

mkdir -p "${output:h}"
cp "${generated}" "${output}"
print "Appcast ready: ${output}"
