#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
: "${MCLASH_XRAY_BINARY:?Set MCLASH_XRAY_BINARY to the pinned Xray executable}"
build_dir="${repo_root}/.build/xray-supervisor-smoke"
mkdir -p "${build_dir}"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "${repo_root}/Sources/MClashApp/App/AppLanguage.swift" \
  "${repo_root}/Sources/MClashApp/App/AppLocalization.swift" \
  "${repo_root}/Sources/MClashApp/Core/CoreModels.swift" \
  "${repo_root}/Sources/MClashApp/Core/CoreSupervisor.swift" \
  "${repo_root}/Tests/Integration/XraySupervisorSmoke.swift" \
  -o "${build_dir}/smoke"

python3 - "${build_dir}/smoke" <<'PY'
import http.server
import os
import subprocess
import sys
import threading

class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = b"mclash-xray-payload\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass

with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin) as origin:
    thread = threading.Thread(target=origin.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env["MCLASH_XRAY_SMOKE_ORIGIN"] = f"http://127.0.0.1:{origin.server_port}/payload"
    try:
        subprocess.run([sys.argv[1]], env=env, check=True, timeout=45)
    finally:
        origin.shutdown()
        thread.join()
PY
