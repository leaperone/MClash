#!/usr/bin/env python3
"""Exercise Xray-backed CLI mode/selection changes with real loopback payloads."""
import argparse
import base64
import copy
import json
import hashlib
import os
from pathlib import Path
import shutil
import socket
import select
import signal
import struct
import socketserver
import subprocess
import tempfile
import threading
import time
import uuid


def identifier():
    return {"rawValue": str(uuid.uuid4())}


def member(node):
    return {"node": {"_0": node["id"]}}


def action(group):
    return {"proxyGroup": {"_0": group["id"]}}


class ResponseServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, label, proxy):
        self.label, self.proxy = label, proxy
        self.delay, self.status, self.forward = 0.0, 200, False
        self.connect_targets = []
        self.allowed_ports = set()
        super().__init__(("127.0.0.1", 0), ResponseHandler)
        threading.Thread(target=self.serve_forever, daemon=True).start()


class ResponseHandler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        line = self.rfile.readline(16385)
        if self.server.proxy:
            if not line.startswith(b"CONNECT "):
                return
            address = line.split()[1].decode()
            self.server.connect_targets.append(address)
            while self.rfile.readline(16385) not in (b"\r\n", b""):
                pass
            if self.server.forward:
                host, port = address.rsplit(":", 1)
                if host != "127.0.0.1" or int(port) not in self.server.allowed_ports:
                    return
                with socket.create_connection((host, int(port)), timeout=5) as upstream:
                    self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    self.wfile.flush()
                    while True:
                        ready, _, _ = select.select([self.request, upstream], [], [], 10)
                        if not ready:
                            return
                        for incoming in ready:
                            data = incoming.recv(65536)
                            if not data:
                                return
                            (upstream if incoming is self.request else self.request).sendall(data)
                return
            self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            self.wfile.flush()
            line = self.rfile.readline(16385)
        if not line.startswith(b"GET "):
            return
        while self.rfile.readline(16385) not in (b"\r\n", b""):
            pass
        time.sleep(self.server.delay)
        body = self.server.label.encode()
        self.wfile.write(f"HTTP/1.1 {self.server.status} Fixture\r\nConnection: close\r\nContent-Length: ".encode()
                         + str(len(body)).encode() + b"\r\n\r\n" + body)
        self.wfile.flush()


class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, transport = self.request
        cursor, labels = 12, []
        while packet[cursor]:
            size = packet[cursor]
            labels.append(packet[cursor + 1:cursor + 1 + size].decode())
            cursor += size + 1
        end = cursor + 5
        self.server.names.append(".".join(labels))
        is_a = packet[cursor + 1:cursor + 3] == b"\x00\x01"
        header = packet[:2] + b"\x81\x80\x00\x01" + struct.pack("!H", int(is_a)) + b"\x00\x00\x00\x00"
        answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x01\x00\x04\x7f\x00\x00\x01" if is_a else b""
        transport.sendto(header + packet[12:end] + answer, self.client_address)


def dns_through_socks(port):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as control:
        control.sendall(b"\x05\x01\x00")
        assert control.recv(2) == b"\x05\x00"
        control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        response = bytearray()
        while len(response) < 10:
            chunk = control.recv(10 - len(response))
            assert chunk, "SOCKS listener closed the UDP association"
            response.extend(chunk)
        assert response[:4] == b"\x05\x00\x00\x01", response[:4]
        endpoint = (socket.inet_ntoa(response[4:8]), struct.unpack("!H", response[8:10])[0])
        name = "capture-dns.mclash.invalid"
        question = b"".join(bytes([len(part)]) + part.encode() for part in name.split(".")) + b"\x00\x00\x01\x00\x01"
        packet = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + question
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.settimeout(5)
            udp.sendto(b"\x00\x00\x00\x01\x08\x08\x08\x08\x00\x35" + packet, endpoint)
            answer, _ = udp.recvfrom(4096)
            assert answer[10:12] == b"\x12\x34" and answer.endswith(b"\x7f\x00\x00\x01"), "DNS capture did not use the configured resolver"
        return name


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def capture_app_window(pid, output):
    program = """
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid
        && ($0[kCGWindowLayer as String] as? Int) == 0
        && (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) > 500
}), let id = window[kCGWindowNumber as String] as? Int else { exit(2) }
print(id)
"""
    window_id = subprocess.check_output(["/usr/bin/swift", "-e", program, str(pid)], text=True).strip()
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-l", window_id, str(output)], check=True)
    assert output.is_file() and output.stat().st_size > 0, "MClash window capture is empty"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", type=Path, help="Optional private node source for public HTTPS acceptance; only aggregate results are recorded")
    parser.add_argument("--preserve-signature", action="store_true", help="Exercise the downloaded signed app without changing its bundle or signature")
    parser.add_argument("--ui-output", type=Path, help="Show and capture only the isolated app's connection-record window")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()
    assert (app / "Contents/Helpers/mclashctl").is_file(), "Pass a built MClash.app"
    namespace = "MClash-XrayProof-" + uuid.uuid4().hex
    support = Path.home() / "Library/Application Support" / namespace
    proof = Path(tempfile.mkdtemp(prefix="mclash-proof-", dir="/tmp"))
    servers, process = [], None
    try:
        origin = ResponseServer("DIRECT", False)
        proxy_a = ResponseServer("NODE_A", True)
        proxy_b = ResponseServer("NODE_B", True)
        servers = [origin, proxy_a, proxy_b]
        for server in [proxy_a, proxy_b]:
            server.allowed_ports = {item.server_address[1] for item in servers}
        proxy_a.delay, proxy_b.delay = 0.005, 0.1
        resolver = socketserver.ThreadingUDPServer(("127.0.0.1", 0), DNSHandler)
        resolver.names = []
        threading.Thread(target=resolver.serve_forever, daemon=True).start()
        servers.append(resolver)
        http_port, socks_port = free_port(), free_port()
        assert http_port != socks_port, "Retry: allocated duplicate entrance ports"
        nodes = [dict(id=identifier(), displayName=name, proto="http", host="127.0.0.1",
                      port=server.server_address[1], parameters={}, sourceLinks=[], tags=[], enabled=True,
                      fingerprint=hashlib.sha256(f"http|127.0.0.1|{server.server_address[1]}|".encode()).hexdigest(),
                      health={"availability": "available", "latencyMilliseconds": latency})
                 for name, server, latency in [("A", proxy_a, 10), ("B", proxy_b, 100)]]
        health = dict(testURL=f"http://127.0.0.1:{origin.server_address[1]}/health", expectedStatus="200",
                      probeInterval=5, probeTimeout=1, selectionCooldown=0)
        group = dict(id=identifier(), name="Auto", type="urlTest", enabled=True,
                     members=[member(node) for node in nodes], memberSelectors=[], healthCheck=health)
        fallback = dict(id=identifier(), name="Failover", type="fallback", enabled=True,
                        members=[member(node) for node in nodes], memberSelectors=[], healthCheck=health)
        balance = dict(id=identifier(), name="Balanced", type="loadBalance", enabled=True,
                       members=[member(node) for node in nodes], memberSelectors=[], healthCheck=health)
        chain = dict(id=identifier(), name="Chain", type="relay", enabled=True,
                     members=[member(node) for node in nodes], memberSelectors=[])
        strict = dict(id=identifier(), name="Strict status", type="fallback", enabled=True,
                      members=[member(node) for node in nodes], memberSelectors=[], healthCheck={**health, "expectedStatus": "204"})
        other = dict(id=identifier(), name="Other", type="select", enabled=True,
                     members=[member(nodes[1])], memberSelectors=[])
        dns = dict(id=identifier(), name="Fixture DNS", mode="redirHost",
                   nameservers=[f"udp://127.0.0.1:{resolver.server_address[1]}"], fallbackNameservers=[], rules=[], takeoverEnabled=True)
        entrances = [dict(id=identifier(), name=name, kind=kind, port=port, bindAddress="127.0.0.1",
                          enabled=True, defaultAction=action(group))
                     for name, kind, port in [("HTTP", "http", http_port), ("SOCKS", "socks5", socks_port)]]
        rule = dict(id=identifier(), priority=1, enabled=True,
                    matchers=[{"port": {"_0": origin.server_address[1]}}],
                    action={"reject": {}}, unavailableFallback="reject")
        geo_rules = [dict(id=identifier(), priority=0, enabled=True,
                          matchers=[{kind: {"_0": value}}],
                          action=action(group), unavailableFallback="reject")
                     for kind, value in [("geoSite", "google"), ("geoIP", "cn")]]
        workspace = dict(id=identifier(), name="Fixture", proxyGroupIDs=[g["id"] for g in [group, other, fallback, balance, chain, strict]],
                         ruleIDs=[rule["id"]] + [entry["id"] for entry in geo_rules], ruleSetIDs=[], nodeIDs=[], dnsPolicyID=dns["id"],
                         entranceIDs=[entry["id"] for entry in entrances], revision=1,
                         routingMode="global", globalProxyGroupID=group["id"])
        write_json(support / "Configuration/manifest.json",
                   dict(schemaVersion=1, nodes=nodes, proxyGroups=[group, other, fallback, balance, chain, strict], sources=[],
                        rules=[rule] + geo_rules, ruleSets=[], dnsPolicies=[dns], entrances=entrances,
                        workspaces=[workspace], currentWorkspaceID=workspace["id"]))
        isolated = proof / "MClash.app"
        subprocess.run(["/usr/bin/ditto", str(app), str(isolated)], check=True)
        plist = str(isolated / "Contents/Info.plist")
        if not args.preserve_signature:
            subprocess.run(["/usr/bin/plutil", "-replace", "CFBundleIdentifier", "-string",
                            "one.leaper.mclash.proof." + uuid.uuid4().hex, plist], check=True)
            subprocess.run(["/usr/bin/plutil", "-replace", "LSMultipleInstancesProhibited", "-bool", "false", plist], check=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(isolated)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = dict(os.environ, MCLASH_TEST_MODE="1", MCLASH_RUNTIME_BACKEND="xray", MCLASH_INSTANCE_NAMESPACE=namespace,
                   MCLASH_APPLICATION_SUPPORT_IDENTIFIER=namespace, MCLASH_AUTOMATION_DIRECTORY_PATH=str(proof))
        with (proof / "app.log").open("w") as log:
            process = subprocess.Popen([str(isolated / "Contents/MacOS/MClash"),
                                        "--mclash-background", "--mclash-test-instance"],
                                       env=env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while not (proof / "endpoint.json").is_file():
            assert process.poll() is None and time.monotonic() < deadline, "App did not publish its automation endpoint"
            time.sleep(0.1)
        endpoint = json.loads((proof / "endpoint.json").read_text())["socketPath"]
        cli = str(isolated / "Contents/Helpers/mclashctl")

        def call(method, params=None, expect_error=False):
            result = subprocess.run([cli, method, "--socket", endpoint, "--params-stdin",
                                     "--timeout", "30"], input=json.dumps(params or {}), capture_output=True, text=True, timeout=35)
            response = json.loads(result.stdout)
            if expect_error:
                assert response.get("error") is not None, (method, "expected rejection")
                return response["error"]
            if "error" in response:
                for diagnostic_method in ["status", "logs.list", "diagnostics.snapshot"]:
                    diagnostic = subprocess.run([cli, diagnostic_method, "--socket", endpoint, "--timeout", "10"],
                                                capture_output=True, text=True, timeout=15)
                    args.output.with_suffix("." + diagnostic_method.replace(".", "-") + ".json").write_text(diagnostic.stdout)
            assert "error" not in response, (method, response.get("error"))
            assert result.returncode == 0, (method, result.stderr)
            return response["result"]

        def fetch(expected, socks=False, rejected=False, observe=False, host=None):
            target_host = host or ("127.0.0.1" if expected == "DIRECT" else "native-route.invalid")
            proxy = (["--socks5-hostname", f"127.0.0.1:{socks_port}"] if socks else
                     ["--proxy", f"http://127.0.0.1:{http_port}", "--proxytunnel"])
            result = subprocess.run(["/usr/bin/curl", "--silent", "--show-error", "--fail",
                                     "--noproxy", "", "--max-time", "10"] + proxy +
                                    [f"http://{target_host}:{origin.server_address[1]}/"],
                                    text=True, capture_output=True, timeout=15)
            if observe:
                return result.stdout if result.returncode == 0 else None
            if rejected:
                assert result.returncode != 0, "REJECT route forwarded a payload"
            else:
                assert result.returncode == 0 and result.stdout == expected, (result.stdout, result.stderr)

        fixture_source = base64.b64encode(f"proxies:\n  - name: Source fixture\n    type: http\n    server: 127.0.0.1\n    port: {proxy_a.server_address[1]}\n".encode()).decode()
        imported = call("profiles.import", {"dataBase64": fixture_source, "fileName": "fixture.yaml", "activate": True})
        encoded_nodes = "vless://00000000-0000-0000-0000-000000000031@encoded-source.invalid:443#Encoded source node\n"
        encoded_profile = call(
            "profiles.import",
            {
                "dataBase64": base64.b64encode(base64.b64encode(encoded_nodes.encode())).decode(),
                "fileName": "encoded-source.txt",
                "activate": False,
            },
        )
        encoded_snapshot = call("configuration.snapshot", {"nodeLimit": 200})
        assert any(
            encoded_profile["id"] in node.get("sourceLinks", [])
            and node.get("proto") == "vless"
            for node in encoded_snapshot["nodes"]["items"]
        ), "MClash did not import an encoded remote-style node source"
        connection_started = time.monotonic()
        call("core.connect")
        ready_seconds = round(time.monotonic() - connection_started, 3)
        state = call("status")
        assert state["core"]["connected"], state
        assert "26.9.9" in state["core"]["version"], state["core"]
        assert state["core"]["activeProfileID"] == imported["id"]
        fetch("NODE_A")
        fetch("NODE_A", socks=True)
        fetch("NODE_A", host="[2001:db8::1]")
        fetch("NODE_A", socks=True, host="[2001:db8::1]")
        time.sleep(1)
        access_records = call("traffic.flows.list", {"limit": 200})
        assert access_records["evidence"] == "mclash-xray-access-log"
        assert access_records["total"] > 0, "MClash did not ingest Xray access records"
        ipv6_records = [record for record in access_records["items"] if "2001:db8::1" in record["destination"]]
        assert {record["inbound"] for record in ipv6_records} == {"HTTP", "SOCKS"}, "IPv6 events lost their destination or entrance"
        assert all(record["outbound"] == "n-" + nodes[0]["id"]["rawValue"].lower() for record in ipv6_records), "IPv6 events lost their node"
        assert not any((record.get("inbound") or "").startswith("probe-") for record in access_records["items"]), "Node health checks appeared as user traffic"
        traffic_snapshot = call("traffic.snapshot")
        assert traffic_snapshot["connectionCountMeaning"] == "recordedEvents"
        assert traffic_snapshot["connectionCount"] >= access_records["total"]
        connection_records = call("traffic.connections.list", {"limit": 200})
        assert connection_records["evidence"] == "mclash-xray-access-log"
        assert connection_records["total"] >= access_records["total"]
        close_error = call("traffic.connections.closeAll", expect_error=True)
        assert "historical events" in close_error["message"]
        assert call("routing.proxy.select", {"group": "Auto", "proxy": "B"})["selected"]
        fetch("NODE_B")
        fetch("NODE_B", socks=True)
        assert call("routing.proxy.clearOverride", {"group": "Auto"})["cleared"]
        fetch("NODE_A")
        call("routing.mode.set", {"mode": "direct"})
        fetch("DIRECT")
        fetch("DIRECT", socks=True)
        fetch("DIRECT", host="direct-dns.mclash.invalid")
        assert "direct-dns.mclash.invalid" in resolver.names, "Direct traffic bypassed configured DNS"
        assert dns_through_socks(socks_port) in resolver.names
        call("routing.mode.set", {"mode": "rule"})
        fetch("", rejected=True)
        fetch("", socks=True, rejected=True)
        fetch("NODE_A", host="www.google.com")
        fetch("NODE_A", socks=True, host="223.5.5.5")
        fetch("", host="www.google.com.invalid", rejected=True)
        call("routing.mode.set", {"mode": "global"})
        assert call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Other"})["selected"]
        fetch("NODE_B")
        source = base64.b64encode(b"proxies:\n  - name: Extra source node\n    type: socks5\n    server: 127.0.0.1\n    port: 9\nmode: direct\nrules:\n  - MATCH,REJECT\n").decode()
        imported = call("profiles.import", {"dataBase64": source, "fileName": "fixture-source.yaml", "activate": True})
        state = call("status")
        assert state["core"]["activeProfileID"] == imported["id"]
        assert state["routing"]["mode"] == "global"
        assert not (support / "Runtime/config.yaml").exists(), "Xray activation generated compatibility YAML"
        fetch("NODE_B")
        call("profiles.import", {"dataBase64": base64.b64encode(b"invalid source").decode(), "fileName": "bad.yaml"}, expect_error=True)
        assert call("status")["core"]["activeProfileID"] == imported["id"]
        fetch("NODE_B")
        def await_payload(expected, timeout=15):
            started = time.monotonic()
            while time.monotonic() - started < timeout:
                if fetch(expected, observe=True) == expected:
                    return round(time.monotonic() - started, 3)
                time.sleep(0.2)
            raise AssertionError("Automatic selection did not reach " + expected)

        call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Auto"})
        proxy_a.delay, proxy_b.delay = 0.2, 0.005
        url_selection_seconds = await_payload("NODE_B")
        call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Failover"})
        await_payload("NODE_A")
        proxy_a.status = 503
        fallback_seconds = await_payload("NODE_B")
        proxy_a.status = 200
        recovery_seconds = await_payload("NODE_A")
        call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Strict status"})
        time.sleep(4)
        fetch("", rejected=True)
        call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Balanced"})
        balanced = {fetch("NODE_A", observe=True) for _ in range(8)}
        assert balanced == {"NODE_A", "NODE_B"}, balanced
        before_a, before_b = len(proxy_a.connect_targets), len(proxy_b.connect_targets)
        proxy_a.forward = proxy_b.forward = True
        call("routing.proxy.select", {"group": "GLOBAL", "proxy": "Chain"})
        fetch("DIRECT")
        assert f"127.0.0.1:{proxy_b.server_address[1]}" in proxy_a.connect_targets[before_a:]
        assert f"127.0.0.1:{origin.server_address[1]}" in proxy_b.connect_targets[before_b:]
        listener_pids = set()
        for port in [http_port, socks_port]:
            listener_pids.update(subprocess.check_output(["/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"], text=True).split())
        assert len(listener_pids) == 1, "HTTP and SOCKS listeners use different core processes"
        core_pid = listener_pids.pop()
        core_rss = int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", core_pid], text=True)) * 1024
        app_rss = int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(process.pid)], text=True)) * 1024
        snapshot = call("configuration.snapshot")
        before_activation = copy.deepcopy(snapshot["document"])
        occupied = copy.deepcopy(before_activation)
        next(entry for entry in occupied["entrances"] if entry["kind"] == "http")["port"] = origin.server_address[1]
        call("configuration.apply", {"document": occupied, "expectedRevision": snapshot["configurationRevision"]})
        candidate_snapshot = call("configuration.snapshot")
        call("configuration.workspace.activate", {"id": occupied["workspaces"][0]["id"],
                                                    "expectedRevision": candidate_snapshot["configurationRevision"]}, expect_error=True)
        assert call("status")["core"]["connected"], "Failed activation did not restore the previous session"
        fetch("DIRECT")
        restored_snapshot = call("configuration.snapshot")
        call("configuration.apply", {"document": before_activation, "expectedRevision": restored_snapshot["configurationRevision"]})
        restored_snapshot = call("configuration.snapshot")
        assert [group.get("healthCheck") for group in restored_snapshot["document"]["proxyGroups"]] == [
            group.get("healthCheck") for group in before_activation["proxyGroups"]], "Automation erased group health settings"
        public_network = []
        if args.profile:
            imported_live = call("profiles.import", {"dataBase64": base64.b64encode(args.profile.read_bytes()).decode(),
                                                       "fileName": "private-sample.yaml", "activate": False})
            snapshot = call("configuration.snapshot", {"nodeLimit": 200})
            candidates = [node for node in snapshot["nodes"]["items"]
                          if imported_live["id"] in node["sourceLinks"] and node["proto"] == "vless" and node["enabled"]][:6]
            assert candidates, "The private source did not contain VLESS samples"
            document = snapshot["document"]
            for policy in document["dnsPolicies"]:
                policy.update(mode="system", nameserversUpdate=[], fallbackNameserversUpdate=[], takeoverEnabled=False)
            probe_group = dict(id=str(uuid.uuid4()), name="Public HTTPS sample", type="select", enabled=True,
                               membersUpdate=[dict(kind="node", id=node["id"]) for node in candidates], memberSelectors=[])
            document["proxyGroups"].append(probe_group)
            for index, node in enumerate(candidates):
                document["nodeSettings"].append(dict(id=node["id"], userAliasUpdate=f"Network sample {index + 1}"))
            document["workspaces"][0]["proxyGroupIDsUpdate"] = [group["id"] for group in document["proxyGroups"]]
            document["workspaces"][0]["globalProxyGroupID"] = probe_group["id"]
            call("configuration.apply", {"document": document, "expectedRevision": snapshot["configurationRevision"]})
            snapshot = call("configuration.snapshot")
            call("configuration.workspace.activate", {"id": document["workspaces"][0]["id"],
                                                        "expectedRevision": snapshot["configurationRevision"]})
            for index, node in enumerate(candidates):
                selected = call("routing.proxy.select", {"group": probe_group["name"], "proxy": f"Network sample {index + 1}"})
                if not selected["selected"]:
                    public_network.append(dict(sample=index + 1, protocol=node["proto"], selected=False))
                    continue
                result = subprocess.run(["/usr/bin/curl", "-sS", "--noproxy", "", "--max-time", "12",
                                         "--proxy", f"http://127.0.0.1:{http_port}", "--output", "/dev/null",
                                         "--write-out", "%{http_code} %{time_total}", "https://www.gstatic.com/generate_204"],
                                        capture_output=True, text=True, timeout=15)
                fields = result.stdout.split()
                public_network.append(dict(sample=index + 1, protocol=node["proto"],
                                           httpStatus=fields[0] if fields else None,
                                           seconds=float(fields[1]) if len(fields) == 2 else None,
                                           passed=result.returncode == 0 and fields[0] == "204"))
                if sum(item.get("passed", False) for item in public_network) >= 2:
                    break
            assert any(item.get("passed") for item in public_network), "No private-source VLESS sample completed public HTTPS"
        if args.ui_output:
            call("app.ui.show", {"destination": "connections"})
            time.sleep(1)
            capture_app_window(process.pid, args.ui_output)
            call("app.ui.show", {"destination": "sources"})
            time.sleep(1)
            capture_app_window(process.pid, args.ui_output.with_name(args.ui_output.stem + ".sources.png"))
        call("core.disconnect")
        assert call("status")["core"]["state"] == "stopped"
        receipt = {"passed": True, "backend": "xray", "http": True, "socks5": True,
                          "modeChanges": ["global", "direct", "rule"],
                          "selectionAndClear": True, "globalExitChange": True, "disconnect": True,
                          "sourceActivation": True, "invalidSourceRejected": True,
                          "automaticURLTest": url_selection_seconds, "automaticFallback": fallback_seconds,
                          "automaticRecovery": recovery_seconds, "expectedStatusEnforced": True,
                          "loadBalance": sorted(balanced), "relayChain": True, "publicHTTPS": public_network}
        receipt["dnsPolicy"] = {"directResolution": True, "socksUDPCapture": True}
        receipt["geoRouting"] = {"geoSitePayload": True, "geoIPPayload": True, "unmatchedRejected": True}
        receipt["failedActivationRollback"] = True
        receipt["healthSettingsRoundTrip"] = True
        receipt["encodedSourceImport"] = True
        receipt["signaturePreserved"] = args.preserve_signature
        receipt["resources"] = dict(coreProcesses=1, coreRSSBytes=core_rss, appRSSBytes=app_rss, connectSeconds=ready_seconds)
        receipt["xrayAccessRecords"] = access_records["total"]
        receipt["ipv6AccessRecords"] = len(ipv6_records)
        receipt["healthProbesExcluded"] = True
        receipt["xrayConnectionRecordCount"] = traffic_snapshot["connectionCount"]
        receipt["xrayConnectionRecordEvidence"] = connection_records["evidence"]
        receipt["xrayCloseRejected"] = True
        args.output.write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt))
    except BaseException:
        if not args.profile:
            for state in support.glob("Runtime/Xray/*/group-state.json"):
                shutil.copyfile(state, args.output.with_suffix(".group-state.json"))
            manifest = support / "Configuration/manifest.json"
            if manifest.exists():
                groups = json.loads(manifest.read_text()).get("proxyGroups", [])
                args.output.with_suffix(".health-settings.json").write_text(json.dumps([
                    dict(id=group["id"], name=group["name"], health=group.get("healthCheck")) for group in groups]))
        raise
    finally:
        if process is not None:
            children = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
            cores = []
            for row in children.splitlines():
                fields = row.strip().split(maxsplit=2)
                if len(fields) == 3 and fields[1] == str(process.pid) and fields[2].endswith("/mclash-xray"):
                    cores.append(int(fields[0]))
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            for pid in cores:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for server in servers:
            server.shutdown()
            server.server_close()
        shutil.rmtree(support, ignore_errors=True)
        if (proof / "app.log").exists():
            shutil.copyfile(proof / "app.log", args.output.with_suffix(".app.log"))
        shutil.rmtree(proof, ignore_errors=True)
        subprocess.run(["/usr/bin/defaults", "delete", "one.leaper.mclash." + namespace],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
