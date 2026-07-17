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

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mclash-dmg.XXXXXX")"
staging="${work_dir}/staging"
read_write_image="${work_dir}/MClash-rw.dmg"
mount_point="/Volumes/${volume_name}"
mkdir -p "${staging}" "${output:h}"
if [[ -e "${mount_point}" ]]; then
  print -u2 "A volume named ${volume_name} is already mounted."
  exit 1
fi

ditto "${app}" "${staging}/${app:t}"
ln -s /Applications "${staging}/Applications"

app_size_kb="$(du -sk "${app}" | awk '{ print $1 }')"
image_size_mb="$(( (app_size_kb / 1024) + 64 ))"
if (( image_size_mb < 128 )); then
  image_size_mb=128
fi

hdiutil create \
  -quiet \
  -size "${image_size_mb}m" \
  -fs APFS \
  -volname "${volume_name}" \
  "${read_write_image}"

device="$(hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  "${read_write_image}" | awk '/^\/dev\// { print $1; exit }')"
if [[ -z "${device}" ]]; then
  print -u2 "Unable to attach the writable disk image."
  exit 1
fi

cleanup_mount() {
  if [[ -n "${device:-}" ]]; then
    hdiutil detach -quiet "${device}" || hdiutil detach -quiet -force "${device}" || true
    device=""
  fi
}
trap cleanup_mount EXIT INT TERM

ditto "${staging}/" "${mount_point}/"
if [[ -f "${app}/Contents/Resources/AppIcon.icns" ]]; then
  cp "${app}/Contents/Resources/AppIcon.icns" "${mount_point}/.VolumeIcon.icns"
  if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "${mount_point}" || true
  fi
fi

# Finder writes a native .DS_Store with a compact two-icon install layout. This
# is cosmetic, so a headless runner may safely fall back to the same clean DMG.
osascript <<APPLESCRIPT &
tell application "Finder"
  tell disk "${volume_name}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {180, 180, 780, 560}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 104
    set text size of theViewOptions to 13
    set position of item "${app:t}" of container window to {170, 180}
    set position of item "Applications" of container window to {430, 180}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
finder_layout_pid=$!
finder_layout_status=124
for attempt in {1..20}; do
  if ! kill -0 "${finder_layout_pid}" 2>/dev/null; then
    set +e
    wait "${finder_layout_pid}"
    finder_layout_status=$?
    set -e
    break
  fi
  sleep 0.5
done
if kill -0 "${finder_layout_pid}" 2>/dev/null; then
  kill "${finder_layout_pid}" 2>/dev/null || true
  wait "${finder_layout_pid}" 2>/dev/null || true
fi
if (( finder_layout_status != 0 )); then
  print -u2 "Warning: Finder layout was unavailable; continuing with the clean icon layout."
fi

sync
cleanup_mount
trap - EXIT INT TERM

hdiutil convert \
  -quiet \
  "${read_write_image}" \
  -format ULFO \
  -o "${output}"

if [[ ! -s "${output}" ]]; then
  print -u2 "Disk image creation failed: ${output}"
  exit 1
fi
print "DMG ready: ${output}"
