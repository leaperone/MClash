#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output_dir="${repo_root}/.build/geodata"
refresh=0

while (( $# > 0 )); do
  case "$1" in
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --refresh)
      refresh=1
      shift
      ;;
    *)
      print -u2 "Unknown argument: $1"
      exit 2
      ;;
  esac
done

if [[ "${refresh}" != "1" ]] && \
   "${repo_root}/scripts/verify-mihomo-geodata.sh" "${output_dir}" >/dev/null 2>&1; then
  print "Using verified cached mihomo GEO snapshot: ${output_dir}"
  exit 0
fi

staging="$(mktemp -d "${TMPDIR:-/tmp}/mclash-geodata.XXXXXX")"
cleanup() { rm -rf "${staging}" }
trap cleanup EXIT

headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
  headers+=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN}}")
fi

metadata="${staging}/release-commit.json"
/usr/bin/curl -fsSL --retry 4 --retry-all-errors \
  "${headers[@]}" \
  https://api.github.com/repos/MetaCubeX/meta-rules-dat/commits/release \
  -o "${metadata}"

source_revision="$(plutil -extract sha raw -o - "${metadata}")"
source_date="$(plutil -extract commit.committer.date raw -o - "${metadata}")"
if [[ ! "${source_revision}" =~ '^[0-9a-f]{40}$' ]]; then
  print -u2 "meta-rules-dat returned an invalid release revision."
  exit 1
fi

raw_base="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/${source_revision}"
typeset -A packaged_names
packaged_names=(
  geoip.metadb geoip.metadb
  geoip.dat GeoIP.dat
  geosite.dat GeoSite.dat
  GeoLite2-ASN.mmdb ASN.mmdb
)

: > "${staging}/SHA256SUMS"
for upstream_name in geoip.metadb geoip.dat geosite.dat GeoLite2-ASN.mmdb; do
  packaged_name="${packaged_names[${upstream_name}]}"
  checksum_file="${staging}/${upstream_name}.sha256sum"
  downloaded_file="${staging}/${packaged_name}"
  /usr/bin/curl -fsSL --retry 4 --retry-all-errors \
    "${raw_base}/${upstream_name}.sha256sum" \
    -o "${checksum_file}"
  /usr/bin/curl -fsSL --retry 4 --retry-all-errors \
    "${raw_base}/${upstream_name}" \
    -o "${downloaded_file}"

  expected_hash="$(awk -v file="${upstream_name}" '$2 == file || $2 == "*" file { print tolower($1); exit }' "${checksum_file}")"
  actual_hash="$(shasum -a 256 "${downloaded_file}" | awk '{ print tolower($1) }')"
  if [[ ! "${expected_hash}" =~ '^[0-9a-f]{64}$' || "${actual_hash}" != "${expected_hash}" ]]; then
    print -u2 "GEO data SHA-256 mismatch for ${upstream_name} at ${source_revision}."
    exit 1
  fi
  print "${actual_hash}  ${packaged_name}" >> "${staging}/SHA256SUMS"
done

fetched_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
  print "Repository: https://github.com/MetaCubeX/meta-rules-dat"
  print "Release branch revision: ${source_revision}"
  print "Revision timestamp: ${source_date}"
  print "Fetched for MClash release: ${fetched_at}"
  print "Files: geoip.metadb, geoip.dat, geosite.dat, GeoLite2-ASN.mmdb"
  print "GeoLite2-ASN.mmdb is packaged as ASN.mmdb for mihomo's home-directory lookup."
} > "${staging}/SOURCE.txt"

"${repo_root}/scripts/verify-mihomo-geodata.sh" "${staging}"
mkdir -p "${output_dir}"
for file_name in geoip.metadb GeoIP.dat GeoSite.dat ASN.mmdb SHA256SUMS SOURCE.txt; do
  cp "${staging}/${file_name}" "${output_dir}/${file_name}"
done
"${repo_root}/scripts/verify-mihomo-geodata.sh" "${output_dir}"

print "Fetched mihomo GEO snapshot ${source_revision} to ${output_dir}"
