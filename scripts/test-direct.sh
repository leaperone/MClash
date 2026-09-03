#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"

run_release_script_tests() {
  python3 "${repo_root}/scripts/test-attach-appcast-deltas.py"
  "${repo_root}/scripts/test-release-preflight.sh"
}

# The direct harness is used in CI as well as locally. It avoids the SwiftPM
# manifest/runtime path that can be out of sync on Command Line Tools runners.
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
tests=("${repo_root}"/Tests/MClashTests/**/*.swift(N))
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

# The Command Line Tools Swift Testing runtime can abort while formatting
# framework values after several suites (for example with signal 5 or the
# arm64e "Not enough bits" trap). Keep each process bounded so one runtime
# abort cannot prevent later test files from running. This is deliberately a
# process split, not a test filter: every source file is compiled and run.
network_test_chunk_size="${MCLASH_NETWORK_TEST_CHUNK_SIZE:-8}"
if [[ ! "${network_test_chunk_size}" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "MCLASH_NETWORK_TEST_CHUNK_SIZE must be a positive integer."
  exit 1
fi

run_network_test_chunks() {
  local target_name="$1"
  local output_prefix="$2"
  shift 2
  local -a library_flags=()
  while (( $# > 0 )) && [[ "$1" != "--" ]]; do
    library_flags+=("$1")
    shift
  done
  if (( $# == 0 )); then
    print -u2 "${target_name} test chunks require a -- delimiter before test files."
    return 1
  fi
  shift
  local -a test_files=("$@")
  local chunk_number=0
  local aggregate_exit=0
  local offset=1
  local total=${#test_files[@]}

  while (( offset <= total )); do
    chunk_number=$((chunk_number + 1))
    local -a chunk=("${test_files[@]:$offset-1:$network_test_chunk_size}")
    local executable="${build_dir}/${output_prefix}-${chunk_number}"
    print "Compiling ${target_name} test chunk ${chunk_number} (${#chunk[@]} files)."
    swiftc \
      -parse-as-library \
      -swift-version 6 \
      -strict-concurrency=complete \
      -warnings-as-errors \
      -target "${target_triple}" \
      -I "${build_dir}" \
      -L "${build_dir}" \
      "${library_flags[@]}" \
      -F "${frameworks}" \
      -framework Testing \
      -plugin-path "${plugins}" \
      "${chunk[@]}" \
      "${repo_root}/Tests/TestRunner.swift" \
      -Xlinker -rpath -Xlinker "${build_dir}" \
      -Xlinker -rpath -Xlinker "${frameworks}" \
      -Xlinker -rpath -Xlinker "${testing_interop}" \
      -o "${executable}"

    local chunk_exit=0
    if SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 "${executable}"; then
      chunk_exit=0
    else
      chunk_exit=$?
    fi
    if (( chunk_exit != 0 )); then
      print -u2 "${target_name} test chunk ${chunk_number} exited with ${chunk_exit}; continuing remaining chunks."
      if (( aggregate_exit == 0 )); then aggregate_exit=${chunk_exit}; fi
    fi
    offset=$((offset + network_test_chunk_size))
  done
  return ${aggregate_exit}
}

shared_test_exit=0
if run_network_test_chunks \
  "MClashNetworkShared" MClashNetworkSharedPackageTests \
  -lMClashNetworkShared -- "${network_shared_tests[@]}"; then
  shared_test_exit=0
else
  shared_test_exit=$?
fi

extension_test_exit=0
if run_network_test_chunks \
  "MClashNetworkExtension" MClashNetworkExtensionPackageTests \
  -lMClashNetworkExtension -lMClashNetworkShared \
  -framework Network -framework NetworkExtension -framework Security -lbsm \
  -- "${network_extension_tests[@]}"; then
  extension_test_exit=0
else
  extension_test_exit=$?
fi

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

automation_test_exit=0
set +e
SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=1 \
  "${build_dir}/MClashAutomationProtocolPackageTests"
automation_test_exit=$?
set -e
if (( automation_test_exit != 0 )); then
  print -u2 "Automation test target exited with ${automation_test_exit}."
fi
run_release_script_tests
if (( shared_test_exit != 0 )); then
  exit "${shared_test_exit}"
fi
if (( extension_test_exit != 0 )); then
  exit "${extension_test_exit}"
fi
if (( automation_test_exit != 0 )); then
  exit "${automation_test_exit}"
fi
