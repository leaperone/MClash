#!/bin/zsh
set -euo pipefail

directory="${1:-}"
if [[ -z "${directory}" || ! -d "${directory}" ]]; then
  print -u2 "Usage: verify-xray-geodata.sh GEODATA_DIRECTORY"
  exit 2
fi

required=(geoip.dat geosite.dat)
manifest="${directory}/XRAY-SHA256SUMS"
[[ -s "${manifest}" ]] || { print -u2 "Xray GEO data manifest is missing in ${directory}."; exit 1; }

for file_name in "${required[@]}"; do
  file_path="${directory}/${file_name}"
  [[ -s "${file_path}" && ! -L "${file_path}" ]] || {
    print -u2 "Required Xray GEO data file is missing or unsafe: ${file_path}"
    exit 1
  }
done

entry_count="$(awk 'NF == 2 { count++ } END { print count + 0 }' "${manifest}")"
[[ "${entry_count}" == "${#required[@]}" ]] || {
  print -u2 "Xray GEO data manifest contains unexpected entries."
  exit 1
}
(
  cd "${directory}"
  shasum -a 256 -c XRAY-SHA256SUMS
)
print "Verified bundled Xray GEO snapshot in ${directory}"
