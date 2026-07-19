#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
sparkle_version="${SPARKLE_VERSION:-2.9.4}"
sparkle_sha256="${SPARKLE_DISTRIBUTION_SHA256:-ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9}"
tools_root="${SPARKLE_TOOLS_DIR:-${repo_root}/.build/sparkle-tools/${sparkle_version}}"
archive="${tools_root}/Sparkle-${sparkle_version}.tar.xz"

if [[ "${sparkle_version}" != "2.9.4" && -z "${SPARKLE_DISTRIBUTION_SHA256:-}" ]]; then
  print -u2 "Set SPARKLE_DISTRIBUTION_SHA256 when overriding SPARKLE_VERSION."
  exit 2
fi

mkdir -p "${tools_root}"

if [[ ! -x "${tools_root}/bin/generate_appcast" ]]; then
  curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors \
    "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz" \
    --output "${archive}"

  actual_sha256="$(shasum -a 256 "${archive}" | awk '{ print $1 }')"
  if [[ "${actual_sha256}" != "${sparkle_sha256}" ]]; then
    print -u2 "Sparkle distribution SHA-256 mismatch."
    print -u2 "Expected: ${sparkle_sha256}"
    print -u2 "Actual:   ${actual_sha256}"
    exit 1
  fi

  tar -xJf "${archive}" -C "${tools_root}"
fi

for tool in BinaryDelta generate_appcast sign_update generate_keys; do
  if [[ ! -x "${tools_root}/bin/${tool}" ]]; then
    print -u2 "Sparkle distribution is missing bin/${tool}."
    exit 1
  fi
done

print -r -- "${tools_root}"
