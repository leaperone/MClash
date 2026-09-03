#!/bin/zsh
set -u

repo_root="${0:A:h:h}"
log_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
log_file="${log_root}/mclash-unit-tests-${GITHUB_RUN_ID:-local}.log"

set +e
set -o pipefail
"${repo_root}/scripts/test-direct.sh" 2>&1 | tee "${log_file}"
test_status=${pipestatus[1]}
set -e

if (( test_status != 0 )); then
  python3 - "${log_file}" <<'PY'
from pathlib import Path
import sys

lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
markers = ("✘", "error:", "Fatal error", "Expectation failed", "failed after")
selected = [line.strip() for line in lines if any(marker in line for marker in markers)]
if not selected:
    selected = [line.strip() for line in lines[-20:] if line.strip()]
message = " | ".join(selected[-20:])[:7000]
message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print(f"::error file=scripts/test-direct.sh,line=1::{message}")
PY
fi

exit "${test_status}"
