#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output_dir="${repo_root}/.build/direct"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:-$("${repo_root}/scripts/fetch-sparkle-tools.sh")}"
mkdir -p "${output_dir}"

sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
network_shared_sources=("${repo_root}"/Sources/MClashNetworkShared/*.swift(N))
network_extension_sources=("${repo_root}"/Sources/MClashNetworkExtension/*.swift(N))

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx14.0" \
  -emit-module \
  -emit-library \
  -module-name MClashNetworkShared \
  "${network_shared_sources[@]}" \
  -emit-module-path "${output_dir}/MClashNetworkShared.swiftmodule" \
  -o "${output_dir}/libMClashNetworkShared.dylib"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework NetworkExtension \
  -framework SystemExtensions \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -lsqlite3 \
  -I "${output_dir}" \
  -L "${output_dir}" \
  -lMClashNetworkShared \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker "@executable_path/../Frameworks" \
  "${sources[@]}" \
  -o "${output_dir}/MClash"

swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-name MClashNetworkExtension \
  -framework Network \
  -framework NetworkExtension \
  -framework Security \
  -lbsm \
  -I "${output_dir}" \
  -L "${output_dir}" \
  -lMClashNetworkShared \
  "${network_extension_sources[@]}" \
  -Xlinker -rpath \
  -Xlinker "${output_dir}" \
  -o "${output_dir}/MClashNetworkExtension"

print "Typecheck and direct link succeeded: ${output_dir}/MClash and MClashNetworkExtension"
