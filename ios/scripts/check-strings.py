#!/usr/bin/env python3
"""Compares the texts the compiler extracted from the app with Localizable.xcstrings.

Build the app first (Debug, simulator), then run: python3 scripts/check-strings.py
Lists German texts without English translation and catalog entries no longer used.
"""
import glob
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
pattern = str(root / "build/DerivedData/Build/Intermediates.noindex/Leuchtturm.build/Debug-iphonesimulator/Leuchtturm.build/Objects-normal/*/*.stringsdata")
keys = set()
for path in glob.glob(pattern):
    for entry in json.loads(pathlib.Path(path).read_text()).get("tables", {}).get("Localizable", []):
        keys.add(entry["key"])
if not keys:
    sys.exit("No extracted strings found. Build the app for the simulator first.")
catalog = json.loads((root / "Leuchtturm/Localizable.xcstrings").read_text())["strings"]
missing = sorted(k for k in keys if "en" not in catalog.get(k, {}).get("localizations", {}))
stale = sorted(set(catalog) - keys)
for k in missing:
    print("missing English:", repr(k))
for k in stale:
    print("unused:", repr(k))
sys.exit(1 if missing else 0)
