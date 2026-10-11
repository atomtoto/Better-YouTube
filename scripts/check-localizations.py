#!/usr/bin/env python3
"""Fails when a string the apps show has no French translation.

Xcode's own export is the source of truth: it extracts every string from the code of every
target — the iPhone, iPad and Mac app, the Watch app, the Siri phrases — exactly as a build
would, so a string added in code and never put in a catalog is caught as well as one sitting in
a catalog untranslated.

The export rewrites the String Catalogs in place as a side effect. They are copied aside first
and put back afterwards, so running this locally leaves the working copy as it found it.

Usage: scripts/check-localizations.py
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

LANGUAGE = "fr"
# Names that read the same in every language.
SAME_IN_EVERY_LANGUAGE = {
    ("InfoPlist.xcstrings", "CFBundleName"),
    ("InfoPlist.xcstrings", "CFBundleDisplayName"),
}
XLIFF = "{urn:oasis:names:tc:xliff:document:1.2}"

project_dir = pathlib.Path(__file__).resolve().parent.parent / "BetterYouTube"
catalogs = sorted(project_dir.rglob("*.xcstrings"))


def export(destination: str) -> pathlib.Path:
    result = subprocess.run(
        [
            "xcodebuild", "-exportLocalizations",
            "-project", str(project_dir / "BetterYouTube.xcodeproj"),
            "-localizationPath", destination,
            "-exportLanguage", LANGUAGE,
            "CODE_SIGNING_ALLOWED=NO",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stdout[-4000:])
        print(result.stderr[-4000:], file=sys.stderr)
        sys.exit(result.returncode)
    return pathlib.Path(destination) / f"{LANGUAGE}.xcloc" / "Localized Contents" / f"{LANGUAGE}.xliff"


with tempfile.TemporaryDirectory() as scratch:
    backup = pathlib.Path(scratch) / "catalogs"
    for catalog in catalogs:
        target = backup / catalog.relative_to(project_dir)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(catalog, target)
    try:
        tree = ET.parse(export(str(pathlib.Path(scratch) / "export")))
    finally:
        for catalog in catalogs:
            shutil.copy2(backup / catalog.relative_to(project_dir), catalog)

missing = []
total = 0
for file in tree.getroot().iter(f"{XLIFF}file"):
    catalog = file.get("original", "")
    for unit in file.iter(f"{XLIFF}trans-unit"):
        total += 1
        key = unit.get("id", "")
        if (pathlib.Path(catalog).name, key) in SAME_IN_EVERY_LANGUAGE:
            continue
        target = unit.find(f"{XLIFF}target")
        if target is None or target.get("state") in ("new", "needs-translation") or not (target.text or "").strip():
            missing.append((catalog, key))

if missing:
    for catalog, key in missing:
        # GitHub shows these as annotations on the run.
        print(f"::error file=BetterYouTube/{catalog}::No French translation for “{key}”")
    print(f"\n{len(missing)} of {total} strings have no French translation.")
    print("Add them in Xcode's String Catalog editor, or to the catalog named above.")
    sys.exit(1)

print(f"All {total} strings have a French translation.")
