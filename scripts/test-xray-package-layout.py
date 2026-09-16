#!/usr/bin/env python3
"""Check that an Xray 1.6 application bundle contains only its Xray core."""
import argparse
from pathlib import Path
import plistlib
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    contents = app / "Contents"
    core = contents / "Resources/Core"
    info_path = contents / "Info.plist"
    if not app.is_dir() or not info_path.is_file():
        raise SystemExit(f"Not an application bundle: {app}")
    info = plistlib.loads(info_path.read_bytes())
    if info.get("MClashRuntimeBackend") != "xray":
        raise SystemExit("Application does not declare the Xray runtime backend")
    xray = core / "mclash-xray"
    legacy = core / "mclash-mihomo"
    if not xray.is_file() or not xray.stat().st_mode & 0o111:
        raise SystemExit("The Xray core is missing or not executable")
    entries = sorted(path.name for path in core.iterdir()) if core.is_dir() else []
    if entries != ["mclash-xray"]:
        raise SystemExit(f"Xray apps must contain only mclash-xray in Resources/Core, found {entries}")
    if legacy.exists():
        raise SystemExit("The legacy proxy core must not be bundled in a 1.6 Xray app")
    if any(path.name.startswith("mihomo-") for path in (contents / "Resources/ThirdParty").glob("*")):
        raise SystemExit("Legacy proxy-core distribution material must not be bundled")
    print(f"Xray package layout passed for {app}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
