#!/bin/zsh
set -euo pipefail

directory="${1:-}"
if [[ -z "${directory}" || ! -d "${directory}" ]]; then
  print -u2 "Usage: verify-mihomo-geodata.sh GEODATA_DIRECTORY"
  exit 2
fi

required=(geoip.metadb GeoIP.dat GeoSite.dat ASN.mmdb)
manifest="${directory}/SHA256SUMS"
source_record="${directory}/SOURCE.txt"

if [[ ! -s "${manifest}" || ! -s "${source_record}" ]]; then
  print -u2 "GEO data manifest or source record is missing in ${directory}."
  exit 1
fi

for file_name in "${required[@]}"; do
  file_path="${directory}/${file_name}"
  if [[ ! -s "${file_path}" || -L "${file_path}" ]]; then
    print -u2 "Required GEO data file is missing or unsafe: ${file_path}"
    exit 1
  fi
  count="$(awk -v file="${file_name}" '$2 == file || $2 == "*" file { count++ } END { print count + 0 }' "${manifest}")"
  if [[ "${count}" != "1" ]]; then
    print -u2 "GEO data manifest must contain exactly one hash for ${file_name}."
    exit 1
  fi
done

entry_count="$(awk 'NF == 2 { count++ } END { print count + 0 }' "${manifest}")"
if [[ "${entry_count}" != "${#required[@]}" ]]; then
  print -u2 "GEO data manifest contains unexpected entries."
  exit 1
fi

(
  cd "${directory}"
  shasum -a 256 -c SHA256SUMS
)

print "Verified bundled mihomo GEO snapshot in ${directory}"
