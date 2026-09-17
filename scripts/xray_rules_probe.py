#!/usr/bin/env python3
"""Verify MClash-owned remote rule-set refreshes through the automation API."""
import copy
import http.server
import socketserver
import threading
import uuid


class _RuleHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        server = self.server
        server.requests.append({
            "ifNoneMatch": self.headers.get("If-None-Match"),
            "path": self.path,
        })
        if self.headers.get("If-None-Match") == server.etag and server.status == 200:
            server.responses.append(304)
            self.send_response(304)
            self.end_headers()
            return
        body = server.body.encode("utf-8")
        server.responses.append(server.status)
        self.send_response(server.status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("ETag", server.etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if server.status != 304:
            self.wfile.write(body)

    def log_message(self, *_args):
        return


class _RuleServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        self.body = "v1.example"
        self.etag = "rules-v1"
        self.status = 200
        self.requests = []
        self.responses = []
        super().__init__(("127.0.0.1", 0), _RuleHandler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}/rules.txt"


def _set_ruleset(document, source_url, group_id, rule_set_id):
    rule_set = {
        "id": rule_set_id,
        "name": "Remote fixture",
        "rulesUpdate": [],
        "ruleCount": 0,
        "defaultAction": {"kind": "proxyGroup", "proxyGroupID": group_id},
        "sourceURLUpdate": source_url,
        "behavior": "domain",
        "format": "text",
        "enabled": True,
    }
    document["ruleSets"] = [entry for entry in document.get("ruleSets", []) if entry.get("id") != rule_set_id]
    document["ruleSets"].append(rule_set)
    for rule in document.get("rules", []):
        rule["enabled"] = False
    for entrance in document.get("entrances", []):
        entrance["defaultAction"] = {"kind": "reject"}
    workspace = document["workspaces"][0]
    workspace["ruleSetIDsUpdate"] = [rule_set_id]
    return rule_set


def exercise_remote_rules(call, fetch):
    """Run the remote rule source contract using existing smoke closures.

    ``call`` is the smoke automation RPC closure and ``fetch`` is its local
    proxy request closure. The returned receipt contains no private URLs.
    """
    server = _RuleServer()
    snapshot = call("configuration.snapshot", {"nodeLimit": 200})
    original = copy.deepcopy(snapshot["document"])
    assert not original["ruleSets"], "Remote rule probe requires the isolated fixture without existing rule sets"
    original["workspaces"][0]["ruleSetIDsUpdate"] = []
    rule_set_id = str(uuid.uuid4())
    group = next((group for group in original["proxyGroups"] if group.get("name") == "Auto"), None)
    if group is None:
        server.shutdown()
        raise AssertionError("Remote rule probe could not find the Auto group")
    active = None
    try:
        candidate = copy.deepcopy(original)
        _set_ruleset(candidate, server.url, group["id"], rule_set_id)
        applied = call("configuration.apply", {
            "document": candidate,
            "expectedRevision": snapshot["configurationRevision"],
        })
        active = candidate
        activated_snapshot = call("configuration.snapshot", {"nodeLimit": 200})
        workspace_id = candidate["workspaces"][0]["id"]
        call("configuration.workspace.activate", {
            "id": workspace_id,
            "expectedRevision": activated_snapshot["configurationRevision"],
        })
        fetch("NODE_A", host="v1.example")
        fetch("", host="unmatched.example", rejected=True)

        server.body, server.etag = "v2.example", "rules-v2"
        updated = call("configuration.ruleSets.refresh")
        assert updated.get("updated") is True, "Remote rule set did not report a successful update"
        fetch("NODE_A", host="v2.example")
        fetch("", host="v1.example", rejected=True)

        server.body, server.etag, server.status = "<!doctype html>", "rules-html", 200
        invalid = call("configuration.ruleSets.refresh")
        assert invalid.get("updated") is False, "Invalid rule payload was reported as updated"
        fetch("NODE_A", host="v2.example")

        server.status = 503
        offline = call("configuration.ruleSets.refresh")
        assert offline.get("updated") is False, "HTTP failure was reported as updated"
        fetch("NODE_A", host="v2.example")

        server.status = 200
        server.body, server.etag = "v2.example", "rules-v2"
        before_304 = len(server.requests)
        conditional = call("configuration.ruleSets.refresh")
        assert conditional.get("updated") is True, "Conditional refresh failed"
        conditional_requests = server.requests[before_304:]
        assert conditional_requests and conditional_requests[-1]["ifNoneMatch"] == "rules-v2", "ETag validator was not sent"
        assert server.responses[-1] == 304, "The rule source did not answer the conditional request with 304"
        fetch("NODE_A", host="v2.example")

        changed_source = call("configuration.snapshot")
        changed_document = copy.deepcopy(changed_source["document"])
        changed_rule_set = next(entry for entry in changed_document["ruleSets"] if entry["id"] == rule_set_id)
        changed_rule_set.update(enabled=False, sourceURLUpdate=server.url + "?source=changed")
        call("configuration.apply", {"document": changed_document,
                                       "expectedRevision": changed_source["configurationRevision"]})
        changed_source = call("configuration.snapshot")
        assert next(entry for entry in changed_source["document"]["ruleSets"] if entry["id"] == rule_set_id)["ruleCount"] == 0, "Changing a disabled source retained rules from its previous URL"
        server.body, server.etag = "v3.example", "rules-v3"
        changed_document = changed_source["document"]
        next(entry for entry in changed_document["ruleSets"] if entry["id"] == rule_set_id)["enabled"] = True
        call("configuration.apply", {"document": changed_document,
                                       "expectedRevision": changed_source["configurationRevision"]})
        changed_source = call("configuration.snapshot")
        call("configuration.workspace.activate", {"id": workspace_id,
                                                   "expectedRevision": changed_source["configurationRevision"]})
        fetch("NODE_A", host="v3.example")
        fetch("", host="v2.example", rejected=True)

        return {
            "passed": True,
            "initialRefresh": True,
            "unmatchedRejected": True,
            "updated": True,
            "oldRuleRejected": True,
            "invalidPayloadPreserved": True,
            "httpFailurePreserved": True,
            "conditional304": True,
            "changedDisabledSourceReloaded": True,
            "conditionalRequestCount": len(conditional_requests),
            "serverStatuses": list(server.responses),
            "configurationApplied": bool(applied),
        }
    finally:
        if active is not None:
            try:
                restored = call("configuration.snapshot", {"nodeLimit": 200})
                original["ruleSets"] = restored["document"]["ruleSets"]
                for entry in original["ruleSets"]:
                    if entry["id"] == rule_set_id:
                        entry["enabled"] = False
                call("configuration.apply", {
                    "document": original,
                    "expectedRevision": restored["configurationRevision"],
                })
                restored = call("configuration.snapshot", {"nodeLimit": 200})
                call("configuration.workspace.activate", {
                    "id": original["workspaces"][0]["id"],
                    "expectedRevision": restored["configurationRevision"],
                })
                restored = call("configuration.snapshot")
                call("configuration.delete", {"kind": "ruleSet", "id": rule_set_id,
                                               "expectedRevision": restored["configurationRevision"]})
            finally:
                server.shutdown()
                server.server_close()
        else:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit("Import exercise_remote_rules from the Xray app smoke harness.")
