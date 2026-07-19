#!/usr/bin/env python3
"""Attach verified Sparkle delta enclosures to one generated appcast item."""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlparse

SPARKLE_NAMESPACES = (
    "http://www.andymatuschak.org/xml-namespaces/sparkle",
    "http://www.sparkle-project.org/xml-namespaces/sparkle",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def load_deltas(path: Path, target_build: str) -> list[dict[str, str]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Could not read delta manifest: {error}")
    if not isinstance(value, list):
        fail("Delta manifest must contain a JSON array.")

    deltas: list[dict[str, str]] = []
    seen_builds: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            fail(f"Delta manifest item {index} must be an object.")
        normalized: dict[str, str] = {}
        for key in ("from", "url", "signature", "length"):
            field = item.get(key)
            if not isinstance(field, str) or not field:
                fail(f"Delta manifest item {index} has an invalid {key}.")
            normalized[key] = field

        if not normalized["from"].isdigit():
            fail(f"Delta manifest item {index} has a non-numeric source build.")
        if normalized["from"] == target_build:
            fail("A delta cannot use the target build as its source build.")
        if normalized["from"] in seen_builds:
            fail(f"Duplicate delta source build: {normalized['from']}")
        seen_builds.add(normalized["from"])
        parsed_url = urlparse(normalized["url"])
        if parsed_url.scheme != "https" or not parsed_url.netloc:
            fail(f"Delta manifest item {index} must use an absolute HTTPS URL.")
        if not normalized["length"].isdigit() or int(normalized["length"]) <= 0:
            fail(f"Delta manifest item {index} has an invalid length.")
        deltas.append(normalized)
    return deltas


def main() -> None:
    if len(sys.argv) != 4:
        fail(
            "Usage: attach-appcast-deltas.py APPCAST TARGET_BUILD DELTA_MANIFEST"
        )

    appcast_path = Path(sys.argv[1])
    target_build = sys.argv[2]
    manifest_path = Path(sys.argv[3])
    if not target_build.isdigit():
        fail("TARGET_BUILD must be numeric.")
    deltas = load_deltas(manifest_path, target_build)

    try:
        tree = ET.parse(appcast_path)
    except (OSError, ET.ParseError) as error:
        fail(f"Could not parse appcast: {error}")
    channel = tree.getroot().find("channel")
    if channel is None:
        fail("Appcast does not contain a channel.")
    sparkle = next(
        (
            namespace
            for namespace in SPARKLE_NAMESPACES
            if channel.find(f"item/{{{namespace}}}version") is not None
        ),
        None,
    )
    if sparkle is None:
        fail("Appcast does not use a supported Sparkle XML namespace.")
    ET.register_namespace("sparkle", sparkle)
    matches = [
        item
        for item in channel.findall("item")
        if item.findtext(f"{{{sparkle}}}version") == target_build
    ]
    if len(matches) != 1:
        fail(
            f"Expected one appcast item for build {target_build}, found {len(matches)}."
        )

    item = matches[0]
    existing = item.find(f"{{{sparkle}}}deltas")
    if existing is not None:
        item.remove(existing)
    if deltas:
        delta_nodes = ET.SubElement(item, f"{{{sparkle}}}deltas")
        for delta in deltas:
            enclosure = ET.SubElement(delta_nodes, "enclosure")
            enclosure.set("url", delta["url"])
            enclosure.set("type", "application/octet-stream")
            enclosure.set("length", delta["length"])
            enclosure.set(f"{{{sparkle}}}deltaFrom", delta["from"])
            enclosure.set(f"{{{sparkle}}}edSignature", delta["signature"])

    ET.indent(tree)
    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    print(f"Attached {len(deltas)} delta update(s) to build {target_build}.")


if __name__ == "__main__":
    main()
