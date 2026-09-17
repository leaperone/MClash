#!/usr/bin/env python3
"""Exercise source selection for signed candidates and tagged releases."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = json.loads(subprocess.check_output([
    "/usr/bin/ruby", "-ryaml", "-rjson", "-e",
    "puts JSON.generate(YAML.load_file(ARGV[0]))", str(ROOT / ".github/workflows/release.yml")
], text=True))
METADATA = WORKFLOW["jobs"]["prepare"]["steps"][0]["run"]
SHA = "a" * 40


def metadata(event, candidate, version="1.6.0"):
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "output"
        environment = dict(os.environ, EVENT_NAME=event, REF_NAME="v" + version,
                           INPUT_VERSION=version, INPUT_BUILD_NUMBER="", INPUT_PRERELEASE="false",
                           INPUT_CANDIDATE_ONLY=str(candidate).lower(), RUN_NUMBER="100",
                           GITHUB_SHA=SHA, GITHUB_OUTPUT=str(output))
        subprocess.run(["/bin/bash"], input=METADATA, text=True, env=environment, check=True)
        return dict(line.split("=", 1) for line in output.read_text().splitlines())


class CandidateModeTests(unittest.TestCase):
    def test_candidate_uses_exact_commit_without_a_tag(self):
        result = metadata("workflow_dispatch", True)
        self.assertEqual(result["source_ref"], SHA)
        self.assertEqual(result["candidate_only"], "true")

    def test_tag_push_keeps_explicit_release_behavior(self):
        result = metadata("push", True)
        self.assertEqual(result["source_ref"], "v1.6.0")
        self.assertEqual(result["candidate_only"], "false")

    def test_manual_publication_requires_tag(self):
        result = metadata("workflow_dispatch", False)
        self.assertEqual(result["source_ref"], "v1.6.0")
        self.assertEqual(result["candidate_only"], "false")

    def test_candidates_cannot_enter_publish_step(self):
        steps = WORKFLOW["jobs"]["release"]["steps"]
        publication = next(step for step in steps if step.get("id") == "publish")
        self.assertEqual(publication["if"], "needs.prepare.outputs.candidate_only != 'true'")
        self.assertNotIn("--clobber", publication["run"])


if __name__ == "__main__":
    unittest.main()
