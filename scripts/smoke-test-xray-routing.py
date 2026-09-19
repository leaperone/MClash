#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


class Origin(socketserver.ThreadingTCPServer):
    daemon_threads = True


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            self.wfile.write(self.server.marker + b":" + line)
            self.wfile.flush()


def read_exact(connection, count):
    data = b""
    while len(data) < count:
        piece = connection.recv(count - len(data))
        if not piece:
            raise EOFError("SOCKS response ended early")
        data += piece
    return data


def socks(port):
    connection = socket.create_connection(("127.0.0.1", port), timeout=3)
    try:
        connection.sendall(b"\x05\x01\x00")
        assert read_exact(connection, 2) == b"\x05\x00"
        connection.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50")
        header = read_exact(connection, 4)
        assert header[1] == 0, f"SOCKS reply {header[1]}"
        address_size = {1: 4, 4: 16}.get(header[3])
        if address_size is None:
            assert header[3] == 3
            address_size = read_exact(connection, 1)[0]
        read_exact(connection, address_size + 2)
        return connection
    except BaseException:
        connection.close()
        raise


def exchange(connection, payload, expected):
    connection.sendall(payload)
    assert read_exact(connection, len(expected)) == expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xray", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    binary = str(pathlib.Path(args.xray).resolve())
    servers, threads, connections = [], [], []
    process = None
    receipt = {"status": "failed", "binary": binary}
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="mcxr-", dir="/tmp") as directory:
        os.chmod(directory, 0o700)
        api_socket = str(pathlib.Path(directory) / "api.sock")
        try:
            for marker in (b"A", b"B"):
                server = Origin(("127.0.0.1", 0), Handler)
                server.marker = marker
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                servers.append(server)
                threads.append(thread)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            config = {
                "log": {"loglevel": "error", "access": "none"},
                "api": {"tag": "api", "listen": api_socket, "services": ["RoutingService", "StatsService"]},
                "stats": {},
                "policy": {"system": {"statsInboundUplink": True, "statsInboundDownlink": True}},
                "inbounds": [{"tag": "input", "listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": {"auth": "noauth"}}],
                "outbounds": [{"tag": f"out-{letter}", "protocol": "freedom", "settings": {"redirect": f"127.0.0.1:{server.server_address[1]}"}}
                              for letter, server in zip(("a", "b"), servers)],
                "routing": {"balancers": [{"tag": "group", "selector": ["out-a"]}],
                            "rules": [{"type": "field", "inboundTag": ["input"], "balancerTag": "group"}]},
            }
            config_path = pathlib.Path(directory) / "config.json"
            config_path.write_text(json.dumps(config))
            subprocess.run([binary, "run", "-test", "-config", str(config_path)], capture_output=True, check=True, timeout=10)
            receipt["version"] = subprocess.run([binary, "version"], capture_output=True, check=True, text=True, timeout=5).stdout.splitlines()[0]
            with open(pathlib.Path(directory) / "core.log", "w") as log:
                started = time.monotonic()
                process = subprocess.Popen([binary, "run", "-config", str(config_path)], stdout=log, stderr=log)
            deadline = started + 5
            while not os.path.exists(api_socket):
                if process.poll() is not None:
                    raise RuntimeError("Xray exited before API readiness")
                if time.monotonic() > deadline:
                    raise TimeoutError("Xray API readiness")
                time.sleep(0.02)

            def api(command, *arguments):
                return subprocess.run([binary, "api", command, "--server=unix:" + api_socket, "--timeout=2", *arguments],
                                      capture_output=True, text=True, check=True, timeout=5).stdout

            api("statsquery")
            receipt["readyMs"] = round((time.monotonic() - started) * 1000, 3)
            receipt["rssBytes"] = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(process.pid)], text=True).strip()) * 1024
            first = socks(port)
            connections.append(first)
            exchange(first, b"one\n", b"A:one\n")
            api("bo", "-b", "group", "out-b")
            second = socks(port)
            connections.append(second)
            exchange(second, b"two\n", b"B:two\n")
            exchange(first, b"still\n", b"A:still\n")
            receipt["selection"] = "new connections switched A to B; established A stream stayed on A"
            api("bo", "-b", "group", "missing")
            rejected = socks(port)
            connections.append(rejected)
            rejected.sendall(b"must-not-leak\n")
            try:
                assert rejected.recv(1) == b"", "Invalid target unexpectedly forwarded data"
            except ConnectionResetError:
                pass
            receipt["invalidOverride"] = "API accepts missing target; actual data connection closes without forwarding"
            for connection in connections:
                connection.close()
            connections.clear()
            stats = json.loads(api("statsquery", "-pattern", "inbound>>>input>>>traffic>>>"))
            counters = {row["name"]: int(row.get("value", 0)) for row in stats.get("stat", [])}
            assert counters.get("inbound>>>input>>>traffic>>>uplink", 0) >= len(b"one\ntwo\nstill\n")
            assert counters.get("inbound>>>input>>>traffic>>>downlink", 0) >= len(b"A:one\nB:two\nA:still\n")
            receipt["counters"] = counters
            process.terminate()
            process.wait(timeout=5)
            with socket.socket() as stopped:
                stopped.settimeout(1)
                assert stopped.connect_ex(("127.0.0.1", port)) != 0, "Xray socket survived stop"
            receipt["stopped"] = True
            receipt["status"] = "passed"
        except BaseException as error:
            receipt["error"] = str(error)
            raise
        finally:
            for connection in connections:
                connection.close()
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            for server in servers:
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join(timeout=2)
            output.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
