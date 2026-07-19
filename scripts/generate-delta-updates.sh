#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
target_app="${1:-}"
full_archive="${2:-}"
output_dir="${3:-}"
manifest="${4:-}"
repository="${GITHUB_REPOSITORY:-leaperone/MClash}"
release_tag="${MCLASH_RELEASE_TAG:-}"
target_version="${MCLASH_VERSION:-}"
target_build="${MCLASH_BUILD_NUMBER:-}"
private_key="${SPARKLE_PRIVATE_KEY:-}"
maximum_deltas="${MCLASH_MAX_DELTAS:-2}"

if [[ -z "${target_app}" || -z "${full_archive}" || -z "${output_dir}" || -z "${manifest}" ]]; then
  print -u2 "Usage: generate-delta-updates.sh TARGET_APP FULL_ARCHIVE OUTPUT_DIR MANIFEST"
  exit 2
fi
if [[ ! -d "${target_app}" || ! -f "${full_archive}" ]]; then
  print -u2 "The target app and full update archive must exist."
  exit 1
fi
if [[ -z "${release_tag}" || -z "${target_version}" || \
      ! "${target_build}" =~ '^[1-9][0-9]*$' || -z "${private_key}" ]]; then
  print -u2 "Set MCLASH_RELEASE_TAG, MCLASH_VERSION, MCLASH_BUILD_NUMBER, and SPARKLE_PRIVATE_KEY."
  exit 2
fi
if [[ ! "${maximum_deltas}" =~ '^[0-9]+$' || "${maximum_deltas}" -gt 5 ]]; then
  print -u2 "MCLASH_MAX_DELTAS must be between 0 and 5."
  exit 2
fi

mkdir -p "${output_dir}" "${manifest:h}"
print -r -- '[]' > "${manifest}"
if [[ "${maximum_deltas}" == "0" ]]; then
  print "Delta generation is disabled; the full Sparkle update remains available."
  exit 0
fi

warn_and_fall_back() {
  print "::warning::$1 The full Sparkle update remains available."
}

for command in gh jq ditto xattr codesign; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    warn_and_fall_back "Delta generation skipped because ${command} is unavailable."
    exit 0
  fi
done

sparkle_tools="$(${repo_root}/scripts/fetch-sparkle-tools.sh)"
binary_delta="${sparkle_tools}/bin/BinaryDelta"
sign_update="${sparkle_tools}/bin/sign_update"
if [[ ! -x "${binary_delta}" || ! -x "${sign_update}" ]]; then
  warn_and_fall_back "Delta generation skipped because Sparkle tools are incomplete."
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-deltas.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT
releases_json="${work_dir}/releases.json"
if ! gh api --paginate "repos/${repository}/releases?per_page=100" > "${releases_json}"; then
  warn_and_fall_back "Previous releases could not be listed."
  exit 0
fi

target_archive_length="$(stat -f '%z' "${full_archive}")"
target_info="${target_app}/Contents/Info.plist"
actual_target_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${target_info}" 2>/dev/null || true)"
actual_target_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "${target_info}" 2>/dev/null || true)"
if [[ "${actual_target_version}" != "${target_version}" || \
      "${actual_target_build}" != "${target_build}" ]]; then
  print -u2 "The target app metadata does not match the requested release."
  exit 1
fi
generated_count=0
while IFS= read -r source_tag; do
  [[ -n "${source_tag}" && "${source_tag}" != "${release_tag}" ]] || continue
  [[ "${source_tag}" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || continue
  source_version="${source_tag#v}"
  source_root="${work_dir}/${source_version}"
  archive_dir="${source_root}/archive"
  extracted_dir="${source_root}/extracted"
  clean_dir="${source_root}/clean"
  applied_dir="${source_root}/applied"
  mkdir -p "${archive_dir}" "${extracted_dir}" "${clean_dir}" "${applied_dir}"

  source_archive_name="MClash-${source_version}-macos-arm64.zip"
  if ! gh release download "${source_tag}" \
      --repo "${repository}" \
      --pattern "${source_archive_name}" \
      --dir "${archive_dir}"; then
    warn_and_fall_back "Could not download the ${source_tag} delta baseline."
    continue
  fi
  source_archive="${archive_dir}/${source_archive_name}"
  if [[ ! -f "${source_archive}" ]] || \
     ! ditto -x -k "${source_archive}" "${extracted_dir}"; then
    warn_and_fall_back "Could not extract the ${source_tag} delta baseline."
    continue
  fi
  source_app="${extracted_dir}/MClash.app"
  source_info="${source_app}/Contents/Info.plist"
  if [[ ! -d "${source_app}" || ! -f "${source_info}" ]]; then
    warn_and_fall_back "The ${source_tag} delta baseline does not contain MClash.app."
    continue
  fi

  source_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${source_info}" 2>/dev/null || true)"
  source_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${source_info}" 2>/dev/null || true)"
  if [[ ! "${source_build}" =~ '^[1-9][0-9]*$' || \
        "${source_build}" -ge "${target_build}" || \
        "${source_short_version}" != "${source_version}" ]]; then
    warn_and_fall_back "The ${source_tag} delta baseline has incompatible version metadata."
    continue
  fi

  clean_app="${clean_dir}/MClash.app"
  if ! ditto "${source_app}" "${clean_app}" || ! xattr -cr "${clean_app}"; then
    warn_and_fall_back "The ${source_tag} delta baseline could not be prepared."
    continue
  fi
  delta="${output_dir}/MClash-${target_version}-from-${source_short_version}-macos-arm64.delta"
  if ! "${binary_delta}" create "${clean_app}" "${target_app}" "${delta}"; then
    rm -f "${delta}"
    warn_and_fall_back "Could not create a delta from ${source_short_version}."
    continue
  fi

  applied_app="${applied_dir}/MClash.app"
  if ! "${binary_delta}" apply "${source_app}" "${applied_app}" "${delta}" || \
     ! codesign --verify --deep --strict "${applied_app}"; then
    rm -f "${delta}"
    warn_and_fall_back "The delta from ${source_short_version} failed apply or code-signing verification."
    continue
  fi
  applied_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "${applied_app}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${applied_build}" != "${target_build}" ]]; then
    rm -f "${delta}"
    warn_and_fall_back "The delta from ${source_short_version} reconstructed the wrong build."
    continue
  fi

  delta_length="$(stat -f '%z' "${delta}")"
  if [[ "${delta_length}" -ge "${target_archive_length}" ]]; then
    rm -f "${delta}"
    warn_and_fall_back "The delta from ${source_short_version} was not smaller than the full update."
    continue
  fi
  if ! signature_output="$(print -rn -- "${private_key}" | \
    "${sign_update}" --ed-key-file - "${delta}")"; then
    rm -f "${delta}"
    warn_and_fall_back "The delta from ${source_short_version} could not be signed."
    continue
  fi
  delta_signature="$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<< "${signature_output}")"
  signed_length="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<< "${signature_output}")"
  if [[ -z "${delta_signature}" || "${signed_length}" != "${delta_length}" ]]; then
    rm -f "${delta}"
    warn_and_fall_back "The delta from ${source_short_version} could not be signed."
    continue
  fi

  delta_name="${delta:t}"
  delta_url="https://github.com/${repository}/releases/download/${release_tag}/${delta_name}"
  jq \
    --arg from "${source_build}" \
    --arg url "${delta_url}" \
    --arg signature "${delta_signature}" \
    --arg length "${delta_length}" \
    '. + [{from: $from, url: $url, signature: $signature, length: $length}]' \
    "${manifest}" > "${manifest}.tmp"
  mv "${manifest}.tmp" "${manifest}"
  (( generated_count += 1 ))
  if [[ "${generated_count}" -ge "${maximum_deltas}" ]]; then
    break
  fi
done < <(
  jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    "${releases_json}"
)

print "Generated ${generated_count} verified delta update(s); the full update remains the fallback."
