#!/usr/bin/env python3
import argparse, json, os, pathlib, socket, socketserver, subprocess, tempfile, threading, time

class Origin(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        marker = self.server.marker
        while True:
            data = self.request.recv(4096)
            if not data: return
            self.request.sendall(marker + b":" + data)

def api(xray, sock, *args, ok=True):
    p = subprocess.run([xray, "api", args[0], "--server=unix:" + sock, *args[1:]], text=True, capture_output=True)
    if (p.returncode == 0) != ok:
        raise RuntimeError("unexpected API result: " + repr((args, p.returncode, p.stdout, p.stderr)))
    return p

def socks(port, destination):
    s = socket.create_connection(("127.0.0.1", port), timeout=3); s.settimeout(3)
    s.sendall(b"\x05\x01\x00"); assert s.recv(2) == b"\x05\x00"
    host = socket.inet_aton("127.0.0.1")
    s.sendall(b"\x05\x01\x00\x01" + host + destination.to_bytes(2, "big"))
    assert s.recv(10)[1] == 0
    return s

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--xray", required=True); ap.add_argument("--output", required=True)
    a = ap.parse_args(); started = None; servers = []; started_at = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="mcx-routing-") as td:
        api_dir = pathlib.Path(td) / "api"; api_dir.mkdir(mode=0o700); api_sock = str(api_dir / "x.sock")
        for port, marker in ((0, b"A"), (0, b"B")):
            srv = Origin(("127.0.0.1", port), Handler); srv.marker = marker
            threading.Thread(target=srv.serve_forever, daemon=True).start(); servers.append(srv)
        probe = socket.socket(); probe.bind(("127.0.0.1", 0)); socks_port = probe.getsockname()[1]; probe.close()
        cfg = {"log":{"loglevel":"error"}, "api":{"tag":"api","services":["RoutingService","StatsService"]},
          "inbounds":[{"tag":"socks","listen":"127.0.0.1","port":socks_port,"protocol":"socks","settings":{"auth":"noauth"}},
                       {"tag":"api","listen":api_sock,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}],
          "outbounds":[{"tag":"out-a","protocol":"freedom","settings":{"redirect":"127.0.0.1:%d" % servers[0].server_address[1]}},
                        {"tag":"out-b","protocol":"freedom","settings":{"redirect":"127.0.0.1:%d" % servers[1].server_address[1]}}, {"tag":"api","protocol":"freedom"}],
          "routing":{"balancers":[{"tag":"group","selector":["out-a"]}],"rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","inboundTag":["socks"],"balancerTag":"group"}]}}
        config = pathlib.Path(td) / "config.json"; config.write_text(json.dumps(cfg))
        check = subprocess.run([a.xray, "run", "-test", "-c", str(config)], capture_output=True, text=True, check=True)
        proc = subprocess.Popen([a.xray, "run", "-c", str(config)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True); started = proc
        try:
            deadline = time.monotonic() + 5
            while not os.path.exists(api_sock):
                if proc.poll() is not None: raise RuntimeError(proc.stderr.read())
                if time.monotonic() > deadline: raise TimeoutError("API socket readiness")
                time.sleep(.02)
            ready_ms = round((time.monotonic() - started_at) * 1000, 1)
            first = socks(socks_port, servers[0].server_address[1]); first.sendall(b"one\n"); assert b"A:one\n" in first.recv(4096)
            api(a.xray, api_sock, "bo", "-b", "group", "out-b")
            second = socks(socks_port, servers[1].server_address[1]); second.sendall(b"two\n"); assert b"B:two\n" in second.recv(4096)
            first.sendall(b"still\n"); assert b"A:still\n" in first.recv(4096)
            api(a.xray, api_sock, "bo", "-b", "group", "missing")
            stats = api(a.xray, api_sock, "statsquery", "inbound>>>socks>>>traffic>>>uplink")
            first.close(); second.close()
            result = {"status":"passed","readyMs":ready_ms,"binary":os.path.realpath(a.xray),"selection":"A -> B","existingStream":"A remained A","invalidOverride":"accepted by API; subsequent selection is failclosed","statsQuery":stats.stdout.strip()}
            pathlib.Path(a.output).write_text(json.dumps(result, indent=2) + "\n")
        finally:
            proc.terminate(); proc.wait(timeout=5)
if __name__ == "__main__": main()
