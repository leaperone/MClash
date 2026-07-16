#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output_dir="${repo_root}/.build/direct"
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
  -framework SwiftUI \
  -framework SystemConfiguration \
  "${sources[@]}" \
  -o "${output_dir}/MClash"

print "Typecheck and direct link succeeded: ${output_dir}/MClash"
