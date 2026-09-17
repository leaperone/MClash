"""Drive only the isolated MClash window through accessibility controls."""
from pathlib import Path
import subprocess
import time


def exercise_ui(call, capture_app_window, process, proxy_a, output):
    control_script = Path(__file__).with_name("verify-app-control.swift")

    def ui_control(action, identifier, *values):
        return subprocess.check_output(["/usr/bin/swift", str(control_script), str(process.pid),
                                        action, identifier, *values], text=True).strip()

    call("app.ui.show", {"destination": "connections"})
    time.sleep(1)
    capture_app_window(process.pid, output)
    ui_control("select-first", "xray.records")
    ui_control("press", "xray.record.details")
    assert ui_control("exists", "xray.record.inspector") == "true"
    capture_app_window(process.pid, output.with_name(output.stem + ".details.png"))
    call("app.ui.show", {"destination": "sources"})
    time.sleep(1)
    capture_app_window(process.pid, output.with_name(output.stem + ".sources.png"))
    sources_before = call("configuration.snapshot")["sources"]["total"]
    ui_control("press", "sources.paste-links")
    time.sleep(0.5)
    ui_control("set", "node-links.input", "not-a-proxy-link")
    assert ui_control("enabled", "node-links.submit") == "false", "Invalid pasted text enabled Add nodes"
    ui_control("set", "node-links.input", f"http://127.0.0.1:{proxy_a.server_address[1]}#UI%20node")
    ui_control("type", "node-links.name", "Added through the UI")
    assert ui_control("enabled", "node-links.submit") == "true", "A valid proxy link cannot be added through the UI"
    capture_app_window(process.pid, output.with_name(output.stem + ".paste.png"))
    ui_control("press", "node-links.submit")
    deadline = time.monotonic() + 10
    while call("configuration.snapshot")["sources"]["total"] != sources_before + 1:
        assert time.monotonic() < deadline, "The UI did not persist its pasted source"
        time.sleep(0.2)
    added = next(source for source in call("configuration.snapshot")["sources"]["items"]
                 if source["displayName"] == "Added through the UI")
    ui_control("press", "sources.edit." + added["id"].lower())
    ui_control("type", "source-editor.name", "Renamed through the UI")
    ui_control("press", "source-editor.save")
    deadline = time.monotonic() + 10
    while not any(source["displayName"] == "Renamed through the UI" for source in call("configuration.snapshot")["sources"]["items"]):
        assert time.monotonic() < deadline, "Source editor did not persist its rename"
        time.sleep(0.2)
    return {"invalidTextRejected": True, "validLinkPreview": True, "sourcePersisted": True, "sourceRenamed": True, "detailsVisible": True}
