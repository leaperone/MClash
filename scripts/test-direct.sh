#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_dir="${repo_root}/.build/direct-tests"
frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
testing_interop="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

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
  -framework SwiftUI \
  -framework SystemConfiguration \
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
  -o "${build_dir}/MClashPackageTests"

"${build_dir}/MClashPackageTests"
