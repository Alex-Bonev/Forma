#!/usr/bin/env python3
"""Pull scans off a connected iPhone and bundle them as the app's demo data.

  scripts/pull_demo_assets.py --device "Rizzlord 9000" --bundle-id com.alexbonev.roomvibe          # list scans
  scripts/pull_demo_assets.py --device ... --bundle-id ... --room "Living Room" --object "Store chair"

Writes RoomVibe/Resources/DemoData/sample_room.json, sample_chair.usdz, sample_chair_thumb.jpg.
"""
import argparse, json, shutil, subprocess, sys, tempfile
from pathlib import Path

DEMO = Path(__file__).resolve().parent.parent / "RoomVibe/Resources/DemoData"

p = argparse.ArgumentParser()
p.add_argument("--device", required=True)
p.add_argument("--bundle-id", required=True)
p.add_argument("--room")
p.add_argument("--object")
a = p.parse_args()

tmp = Path(tempfile.mkdtemp())
subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", a.device,
                "--domain-type", "appDataContainer", "--domain-identifier", a.bundle_id,
                "--source", "Library/Application Support", "--destination", str(tmp), "--quiet"], check=True)
root = next(tmp.rglob("library.json")).parent
lib = json.loads((root / "library.json").read_text())

if not (a.room or a.object):
    print("Rooms:  ", [r["name"] for r in lib["projects"]])
    print("Objects:", [o["name"] for o in lib["objects"] if o.get("modelFile")])
    sys.exit()

def pick(items, name):
    match = [i for i in items if i["name"] == name]
    if not match:
        sys.exit(f"not found: {name!r}")
    return match[0]

if a.room:
    r = pick(lib["projects"], a.room)
    shutil.copy(root / "Projects" / r["id"] / "room.json", DEMO / "sample_room.json")
    print("room ->", DEMO / "sample_room.json")
if a.object:
    o = pick([o for o in lib["objects"] if o.get("modelFile")], a.object)
    src = root / "Objects" / o["id"]
    shutil.copy(src / o["modelFile"], DEMO / "sample_chair.usdz")
    if (src / "thumb.jpg").exists():
        shutil.copy(src / "thumb.jpg", DEMO / "sample_chair_thumb.jpg")
    print("object ->", DEMO / "sample_chair.usdz")
