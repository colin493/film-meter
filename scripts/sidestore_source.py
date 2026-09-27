#!/usr/bin/env python3
"""Write the SideStore source (AltStore source format) for the newest Film Meter build.

Everything that must match the app (bundle ID, version, build number, privacy strings)
is read from the built app's Info.plist, so the source can't drift from the IPA.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib

p = argparse.ArgumentParser()
p.add_argument("--app", required=True, help="path to the built FilmMeter.app")
p.add_argument("--ipa", required=True, help="path to the IPA being published")
p.add_argument("--download-url", required=True)
p.add_argument("--repo", required=True, help="owner/name on GitHub")
p.add_argument("--notes", default="")
p.add_argument("--out", required=True)
a = p.parse_args()

with open(os.path.join(a.app, "Info.plist"), "rb") as f:
    info = plistlib.load(f)

with open(a.ipa, "rb") as f:
    sha256 = hashlib.sha256(f.read()).hexdigest()

privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}
icon = f"https://raw.githubusercontent.com/{a.repo}/main/FilmMeter/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
build = str(info["CFBundleVersion"])
notes = a.notes.strip() or f"Build {build}"
size = os.path.getsize(a.ipa)
tint = "D67834"

version = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": build,
    "date": now,
    "localizedDescription": notes,
    "downloadURL": a.download_url,
    "size": size,
    "sha256": sha256,
    "minOSVersion": info.get("MinimumOSVersion", "18.0"),
}

app = {
    "name": info.get("CFBundleDisplayName", "Film Meter"),
    "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": "Colin Mortimer",
    "subtitle": "Film light meter and preview",
    "localizedDescription": (
        "Meters for the film you have loaded and previews it through that stock's latitude "
        "and your own look. Built for a Contax G2 and a Mamiya 6."
    ),
    "iconURL": icon,
    "tintColor": tint,
    "category": "photo-video",
    "screenshots": [],
    "versions": [version],
    "appPermissions": {"entitlements": [], "privacy": privacy},
    # Older SideStore and AltStore releases read these single-version fields instead.
    "version": version["version"],
    "versionDate": now,
    "versionDescription": notes,
    "downloadURL": a.download_url,
    "size": size,
}

source = {
    "name": "Film Meter",
    "identifier": "com.colinmortimer.filmmeter.source",
    "subtitle": "Builds of Film Meter",
    "description": "Every build of Film Meter from GitHub, newest first.",
    "iconURL": icon,
    "website": f"https://github.com/{a.repo}",
    "tintColor": tint,
    "featuredApps": [app["bundleIdentifier"]],
    "apps": [app],
    "news": [],
}

with open(a.out, "w") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"Wrote {a.out}: {app['name']} {version['version']} ({build}), {size} bytes")
