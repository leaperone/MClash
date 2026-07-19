#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SCRIPT = Path(__file__).with_name("attach-appcast-deltas.py")


class AttachAppcastDeltasTests(unittest.TestCase):
    def test_attaches_verified_metadata_only_to_the_target_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            appcast = root / "appcast.xml"
            manifest = root / "deltas.json"
            appcast.write_text(self.feed(), encoding="utf-8")
            manifest.write_text(
                json.dumps(
                    [
                        {
                            "from": "33",
                            "url": "https://example.invalid/MClash-from-1.1.21.delta",
                            "signature": "delta-signature",
                            "length": "702000",
                        },
                        {
                            "from": "32",
                            "url": "https://example.invalid/MClash-from-1.1.20.delta",
                            "signature": "older-delta-signature",
                            "length": "704000",
                        },
                    ]
                ),
                encoding="utf-8",
            )

            subprocess.run(
                [sys.executable, SCRIPT, appcast, "34", manifest],
                check=True,
            )

            items = ET.parse(appcast).getroot().find("channel").findall("item")
            target = items[0]
            older = items[1]
            self.assertIsNotNone(target.find("enclosure"))
            deltas = target.findall(f"{{{SPARKLE}}}deltas/enclosure")
            self.assertEqual(
                [delta.get(f"{{{SPARKLE}}}deltaFrom") for delta in deltas],
                ["33", "32"],
            )
            self.assertEqual(
                deltas[0].get(f"{{{SPARKLE}}}edSignature"),
                "delta-signature",
            )
            self.assertIsNone(older.find(f"{{{SPARKLE}}}deltas"))

    def test_rejects_duplicate_source_builds_without_rewriting_the_feed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            appcast = root / "appcast.xml"
            manifest = root / "deltas.json"
            original = self.feed()
            appcast.write_text(original, encoding="utf-8")
            entry = {
                "from": "33",
                "url": "https://example.invalid/update.delta",
                "signature": "signature",
                "length": "123",
            }
            manifest.write_text(json.dumps([entry, entry]), encoding="utf-8")

            result = subprocess.run(
                [sys.executable, SCRIPT, appcast, "34", manifest],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Duplicate delta source build", result.stderr)
            self.assertEqual(appcast.read_text(encoding="utf-8"), original)

    def test_accepts_the_modern_sparkle_namespace(self) -> None:
        modern = "http://www.sparkle-project.org/xml-namespaces/sparkle"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            appcast = root / "appcast.xml"
            manifest = root / "deltas.json"
            appcast.write_text(self.feed().replace(SPARKLE, modern), encoding="utf-8")
            manifest.write_text("[]", encoding="utf-8")

            subprocess.run(
                [sys.executable, SCRIPT, appcast, "34", manifest],
                check=True,
            )

            target = ET.parse(appcast).getroot().find("channel").find("item")
            self.assertEqual(target.findtext(f"{{{modern}}}version"), "34")

    @staticmethod
    def feed() -> str:
        return (
            f'<rss xmlns:sparkle="{SPARKLE}" version="2.0"><channel>'
            "<title>MClash</title>"
            "<item><title>1.1.22</title><sparkle:version>34</sparkle:version>"
            "<sparkle:shortVersionString>1.1.22</sparkle:shortVersionString>"
            "<enclosure url=\"1.1.22.zip\" length=\"1000\" "
            "sparkle:edSignature=\"archive-signature\"/></item>"
            "<item><title>1.1.21</title><sparkle:version>33</sparkle:version>"
            "<sparkle:shortVersionString>1.1.21</sparkle:shortVersionString>"
            "<enclosure url=\"1.1.21.zip\" length=\"900\" "
            "sparkle:edSignature=\"old-archive-signature\"/></item>"
            "</channel></rss>"
        )


if __name__ == "__main__":
    unittest.main()
