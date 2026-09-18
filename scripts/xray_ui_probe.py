"""Drive only the isolated MClash window through accessibility controls."""
from pathlib import Path
import subprocess
import time


def exercise_ui(call, capture_app_window, process, proxy_a, output, proxy_b=None, fetch=None):
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
    current = call("configuration.snapshot")
    call("configuration.workspace.activate", {
        "id": current["currentWorkspaceID"],
        "expectedRevision": current["configurationRevision"],
    })
    call("app.ui.show", {"destination": "proxyGroups"})
    time.sleep(1)
    assert ui_control("exists", "configuration.rule-route-strategy") == "true", \
        "The Node Groups page did not expose the rule traffic strategy selector"
    groups = call("routing.groups.list", {"limit": 200})["items"]
    route_group = next(
        (item for item in groups if item["name"] == "🚀 节点选择"),
        None
    )
    if route_group is None:
        route_group = next(item for item in groups if item["name"] == "Auto")
    route_name = route_group["name"]
    choices = call("routing.group.choices.list", {"group": route_name, "limit": 200})["items"]
    regional_payloads = {}
    available_regions = [
        name for name in ["🇯🇵 日本优先", "🇺🇸 美国优先", "🇭🇰 香港优先"]
        if name in choices
    ]
    if len(available_regions) >= 2:
        payload_before = fetch("NODE_A", observe=True) if fetch else None
        for region in available_regions[:2]:
            identifier = "configuration.runtime-group-member-" + region
            assert ui_control("exists", identifier) == "true", \
                f"The rule strategy picker did not expose {region}"
            ui_control("press", identifier)
            if fetch:
                expected_payload = "NODE_A" if region == "🇯🇵 日本优先" else "NODE_B"
                observed = fetch(expected_payload, observe=True)
                regional_payloads[region] = observed
                assert observed == expected_payload, (
                    f"Regional UI selection {region} did not route to its local fixture: {observed}"
                )
            deadline = time.monotonic() + 10
            while True:
                selected = next(
                    item for item in call("routing.groups.list", {"limit": 200})["items"]
                    if item["name"] == route_name
                )["selected"]
                if selected == region:
                    break
                assert time.monotonic() < deadline, \
                    f"The rule strategy picker did not select {region}"
                time.sleep(0.2)
        selected = next(
            item for item in call("routing.groups.list", {"limit": 200})["items"]
            if item["name"] == route_name
        )["selected"]
        assert selected == available_regions[1], "The regional strategy picker lost its selection"
        if fetch and payload_before is not None:
            assert fetch("NODE_B", observe=True) == "NODE_B", \
                "The second regional UI selection did not produce a different payload"
    else:
        strategy = next((item for item in choices if item == "Network sample 1"), choices[0])
        ui_control("set", "configuration.rule-route-strategy", strategy)
        time.sleep(0.8)
        selected = next(
            item for item in call("routing.groups.list", {"limit": 200})["items"]
            if item["name"] == route_name
        )["selected"]
        assert selected == strategy, "The rule traffic strategy selector did not apply its choice"
    capture_app_window(process.pid, output.with_name(output.stem + ".groups.png"))
    return {
        "invalidTextRejected": True,
        "validLinkPreview": True,
        "sourcePersisted": True,
        "sourceRenamed": True,
        "detailsVisible": True,
        "ruleStrategySelectorVisible": True,
        "ruleStrategySelectionApplied": True,
        "regionalPayloads": regional_payloads,
    }
