#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"

run_release_script_tests() {
  python3 "${repo_root}/scripts/test-attach-appcast-deltas.py"
}

# GitHub-hosted runners provide a complete Xcode toolchain, where SwiftPM is
# the stable way to locate Swift Testing and binary-target dependencies. The
# direct path below remains the fallback for standalone Command Line Tools,
# whose PackageDescription dylib can be out of sync with its Swift interface.
if [[ "${CI:-}" == "true" ]]; then
  cd "${repo_root}"
  # Several suites exercise process-wide Apple manager singletons. Swift
  # Testing otherwise runs them concurrently in the same process and can
  # reflect a temporarily null Objective-C singleton after another test tears
  # it down. Pass the explicit SwiftPM flag because the experimental runtime
  # width variable used by the direct runner is not forwarded by `swift test`.
  swift test --configuration debug --no-parallel
  run_release_script_tests
  exit 0
fi

build_dir="${repo_root}/.build/direct-tests"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:-$("${repo_root}/scripts/fetch-sparkle-tools.sh")}"
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
target_triple="$(uname -m)-apple-macosx14.0"
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
if [[ -z "${frameworks}" ]]; then
  testing_framework="$(find "${developer_dir}" -type d -name Testing.framework -print -quit 2>/dev/null)"
  if [[ -n "${testing_framework}" ]]; then
    frameworks="${testing_framework:h}"
  fi
fi

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
if [[ -z "${testing_interop}" ]]; then
  testing_interop_library="$(find "${developer_dir}" -type f -name lib_TestingInterop.dylib -print -quit 2>/dev/null)"
  if [[ -n "${testing_interop_library}" ]]; then
    testing_interop="${testing_interop_library:h}"
  fi
fi

if [[ -z "${frameworks}" || ! -d "${plugins}" || -z "${testing_interop}" ]]; then
  print -u2 "Unable to locate Swift Testing support in ${developer_dir}."
  exit 1
fi

rm -rf "${build_dir}"
mkdir -p "${build_dir}"

sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
tests=("${repo_root}"/Tests/MClashTests/*.swift(N))
automation_sources=("${repo_root}"/Sources/MClashAutomationProtocol/*.swift(N))
automation_tests=("${repo_root}"/Tests/MClashAutomationProtocolTests/*.swift(N))
network_shared_sources=("${repo_root}"/Sources/MClashNetworkShared/*.swift(N))
network_shared_tests=("${repo_root}"/Tests/MClashNetworkSharedTests/*.swift(N))
network_extension_sources=()
for source in "${repo_root}"/Sources/MClashNetworkExtension/*.swift(N); do
  if [[ "${source:t}" != "main.swift" ]]; then
    network_extension_sources+=("${source}")
  fi
done
network_extension_tests=("${repo_root}"/Tests/MClashNetworkExtensionTests/*.swift(N))

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name MClashAutomationProtocol \
  -framework Security \
  "${automation_sources[@]}" \
  -emit-module-path "${build_dir}/MClashAutomationProtocol.swiftmodule" \
  -o "${build_dir}/libMClashAutomationProtocol.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name MClashNetworkShared \
  "${network_shared_sources[@]}" \
  -emit-module-path "${build_dir}/MClashNetworkShared.swiftmodule" \
  -o "${build_dir}/libMClashNetworkShared.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name MClashNetworkExtension \
  -framework Network \
  -framework NetworkExtension \
  -framework Security \
  -lbsm \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashNetworkShared \
  "${network_extension_sources[@]}" \
  -emit-module-path "${build_dir}/MClashNetworkExtension.swiftmodule" \
  -o "${build_dir}/libMClashNetworkExtension.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -target "${target_triple}" \
  -enable-testing \
  -emit-module \
  -emit-library \
  -module-name MClashApp \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework NetworkExtension \
  -framework SystemExtensions \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -lsqlite3 \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashNetworkShared \
  -lMClashAutomationProtocol \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  "${sources[@]}" \
  -emit-module-path "${build_dir}/MClashApp.swiftmodule" \
  -o "${build_dir}/libMClashApp.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -target "${target_triple}" \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashApp \
  -lMClashNetworkShared \
  -lMClashAutomationProtocol \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  -lsqlite3 \
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

# Several AppModel suites intentionally exercise process-wide Apple manager
# singletons. The Command Line Tools Testing runtime can otherwise race while
# formatting those opaque Objective-C values after a test completes, producing
# a false null-pointer abort before the remaining suites run.
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  "${build_dir}/MClashPackageTests"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashNetworkShared \
  -F "${frameworks}" \
  -framework Testing \
  -plugin-path "${plugins}" \
  "${network_shared_tests[@]}" \
  "${repo_root}/Tests/TestRunner.swift" \
  -Xlinker -rpath \
  -Xlinker "${build_dir}" \
  -Xlinker -rpath \
  -Xlinker "${frameworks}" \
  -Xlinker -rpath \
  -Xlinker "${testing_interop}" \
  -o "${build_dir}/MClashNetworkSharedPackageTests"

"${build_dir}/MClashNetworkSharedPackageTests"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashNetworkExtension \
  -lMClashNetworkShared \
  -framework Network \
  -framework NetworkExtension \
  -framework Security \
  -lbsm \
  -F "${frameworks}" \
  -framework Testing \
  -plugin-path "${plugins}" \
  "${network_extension_tests[@]}" \
  "${repo_root}/Tests/TestRunner.swift" \
  -Xlinker -rpath \
  -Xlinker "${build_dir}" \
  -Xlinker -rpath \
  -Xlinker "${frameworks}" \
  -Xlinker -rpath \
  -Xlinker "${testing_interop}" \
  -o "${build_dir}/MClashNetworkExtensionPackageTests"

"${build_dir}/MClashNetworkExtensionPackageTests"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "${target_triple}" \
  -I "${build_dir}" \
  -L "${build_dir}" \
  -lMClashAutomationProtocol \
  -F "${frameworks}" \
  -framework Testing \
  -plugin-path "${plugins}" \
  "${automation_tests[@]}" \
  "${repo_root}/Tests/TestRunner.swift" \
  -Xlinker -rpath \
  -Xlinker "${build_dir}" \
  -Xlinker -rpath \
  -Xlinker "${frameworks}" \
  -Xlinker -rpath \
  -Xlinker "${testing_interop}" \
  -o "${build_dir}/MClashAutomationProtocolPackageTests"

"${build_dir}/MClashAutomationProtocolPackageTests"
run_release_script_tests
