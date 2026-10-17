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


def pull(source):
    """Copy one file/folder from the app's Application Support; returns its local path or None."""
    dest = tmp / source.replace("/", "_")
    r = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", a.device,
                        "--domain-type", "appDataContainer", "--domain-identifier", a.bundle_id,
                        "--source", f"Library/Application Support/{source}", "--destination", str(dest), "--quiet"])
    if r.returncode != 0 or not dest.exists():
        return None
    # devicectl may treat --destination as a folder; find the file inside it.
    return dest if dest.is_file() else next(dest.rglob(Path(source).name), None)


def pick(items, name):
    match = [i for i in items if i["name"] == name]
    if not match:
        sys.exit(f"not found: {name!r}. Run without --room/--object to list scans.")
    return match[0]


try:
    index = pull("library.json")
    if not index:
        sys.exit("No library.json on the device yet. Open the app and save a scan first (is the phone unlocked?).")
    lib = json.loads(index.read_text())

    if not (a.room or a.object):
        print("Rooms:  ", [r["name"] for r in lib["projects"]])
        print("Objects:", [o["name"] for o in lib["objects"] if o.get("modelFile")])
        sys.exit()

    if a.room:
        r = pick(lib["projects"], a.room)
        room = pull(f"Projects/{r['id']}/room.json") or sys.exit("room.json missing on device")
        shutil.copy(room, DEMO / "sample_room.json")
        print("room ->", DEMO / "sample_room.json")
    if a.object:
        o = pick([o for o in lib["objects"] if o.get("modelFile")], a.object)
        model = pull(f"Objects/{o['id']}/{o['modelFile']}") or sys.exit("model file missing on device")
        shutil.copy(model, DEMO / "sample_chair.usdz")
        thumb = pull(f"Objects/{o['id']}/thumb.jpg")
        if thumb:
            shutil.copy(thumb, DEMO / "sample_chair_thumb.jpg")
        print("object ->", DEMO / "sample_chair.usdz")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
