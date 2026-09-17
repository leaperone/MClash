"""Verify rotation of the isolated app's logs while its proxy keeps running."""
import time
import uuid

from xray_recovery_probe import _child_xray_pids


def exercise_log_retention(call, fetch, app_pid, support):
    workspace_id = call("status")["configuration"]["workspaceID"]
    directory = support / "Runtime/Xray" / workspace_id
    assert directory.resolve().parent == (support / "Runtime/Xray").resolve()
    before_pids = _child_xray_pids(app_pid)
    assert len(before_pids) == 1, "Log rotation needs one owned Xray process"
    assert call("routing.proxy.select", {"group": "Auto", "proxy": "Source fixture"})["selected"]
    listener_names = {
        listener["name"]
        for listener in call("status")["core"].get("listeners", [])
        if listener.get("kind") in {"http", "socks", "socks5", "mixed"}
    }
    assert len(listener_names) == 2, "Retention fixture must have HTTP and SOCKS entrances"
    paths = [directory / name for name in ("access.log", "error.log")]
    block = b"#" + b"x" * 1022 + b"\n"
    for path in paths:
        assert path.is_file() and not path.is_symlink(), "The isolated log is not a regular file"
        with path.open("ab") as handle:
            for _ in range(9 * 1024):
                handle.write(block)
    started = time.monotonic()
    while True:
        fetch("NODE_A")
        fetch("NODE_A", socks=True)
        assert _child_xray_pids(app_pid) == before_pids, "Log rotation restarted the core process"
        if all(path.is_file() and path.stat().st_size < 8 * 1024 * 1024
               and path.with_name(path.name + ".previous").is_file() for path in paths):
            break
        assert time.monotonic() - started < 45, "MClash did not rotate both oversized logs"
        time.sleep(0.5)
    host = "after-rotation-" + uuid.uuid4().hex + ".invalid"
    fetch("NODE_A", host=host)
    fetch("NODE_A", socks=True, host=host)
    deadline = time.monotonic() + 10
    while True:
        page = call("traffic.flows.list", {"limit": 200})
        if page["total"] > 200:
            page = call("traffic.flows.list", {"offset": page["total"] - 200, "limit": 200})
        records = page["items"]
        entrances = {record.get("inbound") for record in records if record["destination"].startswith(host + ":")}
        if listener_names.issubset(entrances):
            break
        assert time.monotonic() < deadline, "New records did not arrive after log rotation"
        time.sleep(0.2)
    return {"passed": True, "corePIDUnchanged": True, "httpAndSOCKSContinued": True,
            "newRecordsObserved": True, "rotationSeconds": round(time.monotonic() - started, 3),
            "previousFiles": len(list(directory.glob("*.log.previous")))}
