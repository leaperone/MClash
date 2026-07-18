#!/bin/zsh
set -euo pipefail

app="${1:-}"
output="${2:-}"
volume_name="${3:-MClash}"

if [[ -z "${app}" || -z "${output}" ]]; then
  print -u2 "Usage: create-dmg.sh APP_PATH OUTPUT_DMG [VOLUME_NAME]"
  exit 2
fi
if [[ ! -d "${app}" || "${app:e}" != "app" ]]; then
  print -u2 "Application bundle does not exist: ${app}"
  exit 1
fi
if [[ -e "${output}" ]]; then
  print -u2 "Refusing to overwrite an existing disk image: ${output}"
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-dmg.XXXXXX")"
staging="${work_dir}/staging"
mkdir -p "${staging}" "${output:h}"

print "Staging ${app:t} for the installer disk image..."
ditto "${app}" "${staging}/${app:t}"
ln -s /Applications "${staging}/Applications"

# Build the final compressed image directly from the staging folder. The old
# implementation attached a writable image under /Volumes and drove Finder via
# AppleScript to create a cosmetic .DS_Store. That made headless CI depend on
# Finder and on a globally unique mount point, and could fail without a useful
# diagnostic. A direct read-only image preserves the standard drag-to-Applications
# layout without mounting anything or launching Finder.
print "Creating compressed disk image ${output:t}..."
create_output=""
if ! create_output="$(hdiutil create \
  -srcfolder "${staging}" \
  -volname "${volume_name}" \
  -fs APFS \
  -format ULFO \
  "${output}" 2>&1)"; then
  print -u2 "Disk image creation failed: ${output}"
  print -u2 -r -- "${create_output}"
  exit 1
fi

if [[ ! -s "${output}" ]]; then
  print -u2 "Disk image creation produced no output: ${output}"
  exit 1
fi
if ! hdiutil verify "${output}" >/dev/null; then
  print -u2 "Disk image verification failed: ${output}"
  exit 1
fi

print "DMG ready: ${output}"
