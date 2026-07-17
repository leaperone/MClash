#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output_dir="${repo_root}/.build/direct"
sparkle_framework_dir="${SPARKLE_FRAMEWORK_DIR:-$("${repo_root}/scripts/fetch-sparkle-tools.sh")}"
mkdir -p "${output_dir}"

sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework SwiftUI \
  -framework SystemConfiguration \
  -framework UserNotifications \
  -F "${sparkle_framework_dir}" \
  -framework Sparkle \
  -Xlinker -rpath \
  -Xlinker "@executable_path/../Frameworks" \
  "${sources[@]}" \
  -o "${output_dir}/MClash"

print "Typecheck and direct link succeeded: ${output_dir}/MClash"
