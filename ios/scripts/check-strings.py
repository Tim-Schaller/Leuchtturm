#!/usr/bin/env python3
"""Compares the texts the compiler extracted with the string catalogs.

Build the app (iOS simulator, includes widgets and watch) and the TV app
(tvOS simulator) first, then run: python3 scripts/check-strings.py
Lists texts without a translation in any language and catalog entries no
longer used.
"""
import glob
import json
import pathlib
import sys

LANGUAGES = ["en", "fr", "es", "it", "nl", "pl", "tr"]
root = pathlib.Path(__file__).resolve().parent.parent
build = root / "build/DerivedData/Build/Intermediates.noindex/Leuchtturm.build"
targets = [
    ("Leuchtturm", "Debug-iphonesimulator", "Leuchtturm/Localizable.xcstrings"),
    ("LeuchtturmWidgets", "Debug-iphonesimulator", "LeuchtturmWidgets/Localizable.xcstrings"),
    ("LeuchtturmWatch", "Debug-watchsimulator", "LeuchtturmWatch/Localizable.xcstrings"),
    ("LeuchtturmTV", "Debug-appletvsimulator", "LeuchtturmTV/Localizable.xcstrings"),
]
failed = False
for target, platform, catalog_path in targets:
    keys = set()
    for path in glob.glob(str(build / platform / f"{target}.build/Objects-normal/*/*.stringsdata")):
        for entry in json.loads(pathlib.Path(path).read_text()).get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    if not keys:
        print(f"{target}: no extracted strings found, build it for the simulator first.")
        failed = True
        continue
    catalog = json.loads((root / catalog_path).read_text())["strings"]
    for k in sorted(keys):
        missing = [l for l in LANGUAGES if l not in catalog.get(k, {}).get("localizations", {})]
        if missing:
            print(f"{target}: missing {','.join(missing)}: {k!r}")
            failed = True
    for k in sorted(set(catalog) - keys):
        print(f"{target}: unused: {k!r}")
info = json.loads((root / "Leuchtturm/InfoPlist.xcstrings").read_text())["strings"]
for k, v in info.items():
    missing = [l for l in LANGUAGES if l not in v.get("localizations", {})]
    if missing:
        print(f"InfoPlist: missing {','.join(missing)}: {k}")
        failed = True
sys.exit(1 if failed else 0)
