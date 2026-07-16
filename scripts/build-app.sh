#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
configuration="${CONFIGURATION:-release}"
build_root="${repo_root}/.build/${configuration}"
app_bundle="${build_root}/MClash.app"
contents="${app_bundle}/Contents"

"${repo_root}/scripts/typecheck.sh"

rm -rf "${app_bundle}"
mkdir -p "${contents}/MacOS" "${contents}/Resources"
cp "${repo_root}/.build/direct/MClash" "${contents}/MacOS/MClash"
cp "${repo_root}/Support/Info.plist" "${contents}/Info.plist"
cp -R "${repo_root}/Sources/MClashApp/Resources/." "${contents}/Resources/"

codesign --force --deep --sign - "${app_bundle}"
print "Built ${app_bundle}"
