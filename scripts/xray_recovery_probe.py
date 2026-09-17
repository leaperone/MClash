#!/usr/bin/env python3
"""Small recovery probe reused by the application smoke test.

The caller owns the fixture servers and RPC process. This helper only targets
the Xray child whose parent is that process; it never searches for or signals a
system-wide process.
"""
import os
import signal
import subprocess
import time
import uuid


RECOVERY_DEADLINE_SECONDS = 20


def _child_xray_pids(app_pid):
    rows = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True
    ).splitlines()
    result = []
    for row in rows:
        fields = row.strip().split(maxsplit=2)
        if len(fields) == 3 and fields[1] == str(app_pid) and fields[2].endswith("/mclash-xray"):
            command = subprocess.run(["/bin/ps", "-p", fields[0], "-o", "args="], capture_output=True, text=True)
            if command.returncode == 0 and "/mclash-xray run " in command.stdout:
                result.append(int(fields[0]))
    return result


def exercise_recovery(call, fetch, app_pid):
    """Terminate one owned Xray child and prove the app reconnects.

    `call` and `fetch` are the existing smoke test closures. The returned
    receipt contains the exact child PIDs and elapsed recovery time.
    """
    before = _child_xray_pids(app_pid)
    if len(before) != 1:
        raise AssertionError(f"expected exactly one Xray child under app {app_pid}, got {before}")
    old_pid = before[0]
    if old_pid not in _child_xray_pids(app_pid):
        raise AssertionError("Owned Xray child exited before the recovery probe could signal it")
    os.kill(old_pid, signal.SIGTERM)
    started = time.monotonic()
    replacement = None
    while time.monotonic() - started < RECOVERY_DEADLINE_SECONDS:
        current = _child_xray_pids(app_pid)
        if old_pid not in current and len(current) == 1:
            state = call("status")
            if state["core"].get("connected") and state["core"].get("controller") == "ready":
                replacement = current[0]
                break
        time.sleep(0.2)
    if replacement is None:
        raise AssertionError(
            f"Xray child did not recover within {RECOVERY_DEADLINE_SECONDS}s "
            f"(old={old_pid}, current={_child_xray_pids(app_pid)})"
        )

    unique_host = "recovery-" + uuid.uuid4().hex + ".mclash.invalid"
    fetch("NODE_A", host=unique_host)
    fetch("NODE_A", socks=True, host=unique_host)
    observed = []
    while time.monotonic() - started < RECOVERY_DEADLINE_SECONDS:
        observed = [record for record in call("traffic.flows.list", {"limit": 200})["items"]
                    if record["destination"].startswith(unique_host + ":")]
        if {record.get("inbound") for record in observed} == {"HTTP", "SOCKS"}:
            break
        time.sleep(0.2)
    else:
        raise AssertionError("HTTP and SOCKS connection records did not resume after the owned core restarted")
    elapsed = round(time.monotonic() - started, 3)
    call("core.disconnect")
    time.sleep(2)
    if call("status")["core"]["state"] != "stopped":
        raise AssertionError("deliberate disconnect did not remain stopped")
    if _child_xray_pids(app_pid):
        raise AssertionError("deliberate disconnect left an owned Xray process running")
    call("core.connect")
    if not call("status")["core"].get("connected"):
        raise AssertionError("explicit reconnect after deliberate disconnect failed")
    fetch("NODE_A")
    fetch("NODE_A", socks=True)
    return {
        "oldPID": old_pid,
        "replacementPID": replacement,
        "recoverySeconds": elapsed,
        "newConnectionRecords": len(observed),
        "deliberateDisconnect": True,
        "explicitReconnect": True,
        "deadlineSeconds": RECOVERY_DEADLINE_SECONDS,
    }
