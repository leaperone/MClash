#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_dir="${repo_root}/.build/direct-tests"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:-$("${repo_root}/scripts/fetch-sparkle-tools.sh")}"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
runtime_resource_path="$(swiftc -print-target-info | \
  plutil -extract paths.runtimeResourcePath raw -o - -)"
plugins="${runtime_resource_path}/host/plugins/testing"

frameworks=""
for candidate in \
  "${developer_dir}/Library/Developer/Frameworks" \
  "${developer_dir}/Platforms/MacOSX.platform/Developer/Library/Frameworks"
do
  if [[ -d "${candidate}/Testing.framework" ]]; then
    frameworks="${candidate}"
    break
  fi
done

testing_interop=""
for candidate in \
  "${developer_dir}/Library/Developer/usr/lib" \
  "${developer_dir}/Platforms/MacOSX.platform/Developer/usr/lib"
do
  if [[ -f "${candidate}/lib_TestingInterop.dylib" ]]; then
    testing_interop="${candidate}"
    break
  fi
done

if [[ -z "${frameworks}" || ! -d "${plugins}" || -z "${testing_interop}" ]]; then
  print -u2 "Unable to locate Swift Testing support in ${developer_dir}."
  exit 1
fi

rm -rf "${build_dir}"
mkdir -p "${build_dir}"

sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
tests=("${repo_root}"/Tests/MClashTests/*.swift(N))

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name MClashApp \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  "${sources[@]}" \
  -emit-module-path "${build_dir}/MClashApp.swiftmodule" \
  -o "${build_dir}/libMClashApp.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashApp \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  -F "${frameworks}" \
  -framework Testing \
  -plugin-path "${plugins}" \
  "${tests[@]}" \
  "${repo_root}/Tests/TestRunner.swift" \
  -Xlinker -rpath \
  -Xlinker "${build_dir}" \
  -Xlinker -rpath \
  -Xlinker "${frameworks}" \
  -Xlinker -rpath \
  -Xlinker "${testing_interop}" \
  -Xlinker -rpath \
  -Xlinker "${sparkle_framework_dir}" \
  -o "${build_dir}/MClashPackageTests"

"${build_dir}/MClashPackageTests"
