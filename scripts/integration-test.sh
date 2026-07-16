#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
source "${repo_root}/scripts/mihomo-alpha-common.sh"

build_dir="${repo_root}/.build/integration"
architecture="$(uname -m)"
core_pid=""

cleanup() {
  if [[ -n "${core_pid}" ]] && kill -0 "${core_pid}" 2>/dev/null; then
    kill -TERM "${core_pid}" 2>/dev/null || true
    wait "${core_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "${build_dir}"
mihomo_alpha_select_architecture "${architecture}"
core="${MIHOMO_ALPHA_RESOURCE_PATH}"

if [[ ! -f "${core}" ]]; then
  "${repo_root}/scripts/fetch-mihomo-alpha.sh" --architecture "${architecture}"
fi
mihomo_alpha_verify_selected_artifact

swiftc -swift-version 6 \
  "${repo_root}/Sources/MClashApp/Core/CoreModels.swift" \
  "${repo_root}/Sources/MClashApp/Core/CoreBinaryLocator.swift" \
  "${repo_root}/Sources/MClashApp/Core/CoreSupervisor.swift" \
  "${repo_root}/Tests/Integration/CoreSupervisorSmoke.swift" \
  -o "${build_dir}/core-supervisor-smoke"
(
  cd "${repo_root}"
  "${build_dir}/core-supervisor-smoke"
)

application_sources=("${repo_root}"/Sources/MClashApp/**/*.swift(N))
application_sources=("${(@)application_sources:#*/App/MClashApp.swift}")
swiftc -parse-as-library -swift-version 6 \
  -framework AppKit \
  -framework Security \
  -framework SwiftUI \
  -framework SystemConfiguration \
  "${application_sources[@]}" \
  "${repo_root}/Tests/Integration/AppModelSmoke.swift" \
  -o "${build_dir}/app-model-smoke"
(
  cd "${repo_root}"
  "${build_dir}/app-model-smoke"
)

swiftc -swift-version 6 -framework SystemConfiguration \
  "${repo_root}"/Sources/MClashApp/SystemProxy/*.swift \
  "${repo_root}/Tests/Integration/SystemProxyReadSmoke.swift" \
  -o "${build_dir}/system-proxy-read-smoke"
"${build_dir}/system-proxy-read-smoke"

mkdir -p "${build_dir}/api-core-home"
"${core}" \
  -d "${build_dir}/api-core-home" \
  -f "${repo_root}/Tests/Fixtures/minimal.yaml" \
  -ext-ctl 127.0.0.1:19090 \
  -secret integration-secret \
  > "${build_dir}/api-core.log" 2>&1 &
core_pid="$!"

for _ in {1..60}; do
  if curl -fsS -H 'Authorization: Bearer integration-secret' \
    http://127.0.0.1:19090/version >/dev/null; then
    break
  fi
  sleep 0.1
done

swiftc -swift-version 6 \
  "${repo_root}"/Sources/MClashApp/MihomoAPI/*.swift \
  "${repo_root}/Tests/Integration/MihomoAPISmoke.swift" \
  -o "${build_dir}/mihomo-api-smoke"
"${build_dir}/mihomo-api-smoke"

cleanup
core_pid=""

if [[ -n "${MCLASH_TEST_SUBSCRIPTION:-}" ]]; then
  swiftc -swift-version 6 \
    "${repo_root}"/Sources/MClashApp/Profiles/*.swift \
    "${repo_root}/Tests/Integration/ProfileRemoteSmoke.swift" \
    -o "${build_dir}/profile-remote-smoke"
  MCLASH_TEST_CORE="${core}" "${build_dir}/profile-remote-smoke"
fi

print "All MClash integration smoke tests passed"
