#!/bin/zsh
set -euo pipefail

core="${1:-}"
geodata="${2:-}"
if [[ -z "${core}" || ! -x "${core}" || -z "${geodata}" || ! -d "${geodata}" ]]; then
  print -u2 "Usage: smoke-test-mihomo-geodata.sh MIHOMO_BINARY GEODATA_DIRECTORY"
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-geodata-smoke.XXXXXX")"
cleanup() { rm -rf "${work_dir}" }
trap cleanup EXIT

for mode in default geodata; do
  home="${work_dir}/${mode}-home"
  config="${work_dir}/${mode}.yaml"
  mkdir -p "${home}"
  for file_name in geoip.metadb GeoIP.dat GeoSite.dat ASN.mmdb; do
    cp "${geodata}/${file_name}" "${home}/${file_name}"
  done

  {
    if [[ "${mode}" == "geodata" ]]; then
      print 'geodata-mode: true'
    fi
    print 'geox-url:'
    print '  mmdb: http://127.0.0.1:1/geoip.metadb'
    print '  geoip: http://127.0.0.1:1/GeoIP.dat'
    print '  geosite: http://127.0.0.1:1/GeoSite.dat'
    print '  asn: http://127.0.0.1:1/ASN.mmdb'
    print 'mode: rule'
    print 'log-level: warning'
    print 'proxies: []'
    print 'proxy-groups: []'
    print 'rules:'
    print '  - GEOIP,CN,DIRECT'
    print '  - GEOSITE,CN,DIRECT'
    print '  - IP-ASN,4134,DIRECT'
    print '  - MATCH,DIRECT'
  } > "${config}"

  "${core}" -t -d "${home}" -f "${config}"
done

print "mihomo GEO data offline smoke passed in MMDB and GeoData modes"
