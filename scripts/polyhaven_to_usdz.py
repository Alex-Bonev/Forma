#!/usr/bin/env python3
"""Poly Haven model (CC0) -> RealityKit-friendly USDZ, using only /usr/bin USD tools.
usage: python3 -I polyhaven_to_usdz.py <asset_id> <download_dir> <out_dir> [res=1k]
Downloads the 1k .usdc, swaps every texture to its JPG variant (USDZ can't hold EXR),
drops the Blender MaterialX surface (keeps UsdPreviewSurface), wraps in a Y-up root
(Blender exports Z-up; result: up=+Y, front=-Z like the Kenney set), flattens, usdzips, runs usdchecker --arkit."""
import json, os, re, subprocess, sys, urllib.request

aid, dl, out = sys.argv[1:4]; res = sys.argv[4] if len(sys.argv) > 4 else "1k"
UA = {"User-Agent": "RoomVibe-asset-fetch"}
get = lambda u: urllib.request.urlopen(urllib.request.Request(u, headers=UA)).read()
run = lambda *a: subprocess.run(a, check=True, capture_output=True, text=True).stdout

d = os.path.join(dl, aid); os.makedirs(os.path.join(d, "textures"), exist_ok=True)
os.makedirs(os.path.join(out, aid, "textures"), exist_ok=True)
files = json.loads(get(f"https://api.polyhaven.com/files/{aid}"))
usd = list(files["usd"][res].values())[0]
src = os.path.join(d, f"{aid}.usdc"); open(src, "wb").write(get(usd["url"]))

text = run("usdcat", src)
text = re.sub(r"^.*outputs:mtlx:surface\.connect.*\n", "", text, flags=re.M)  # PreviewSurface only
def drop_mtlx(text):  # delete NodeGraph prims and ND_* (MaterialX) shader prims, by indentation
    lines, keep, i = text.split("\n"), [], 0
    while i < len(lines):
        m = re.match(r"( *)def (NodeGraph|Shader) ", lines[i])
        if m:
            j = i + 1
            while lines[j] != m.group(1) + "}": j += 1
            if m.group(2) == "NodeGraph" or 'info:id = "ND_' in "\n".join(lines[i:j]):
                i = j + 1; continue
        keep.append(lines[i]); i += 1
    return "\n".join(keep)
text = drop_mtlx(text)
texs = sorted(set(re.findall(r"@\./textures/([^@]+)\.(?:exr|png|jpg)@", text)))
for t in texs:  # every Poly Haven model map has a JPG variant at this URL
    jpg = os.path.join(out, aid, "textures", t + ".jpg")
    open(jpg, "wb").write(get(f"https://dl.polyhaven.org/file/ph-assets/Models/jpg/{res}/{aid}/{t}.jpg"))
text = re.sub(r"(@\./textures/[^@]+)\.(?:exr|png)@", r"\1.jpg@", text)
# ponytail: opacity maps lose alpha as JPG; fine for furniture, revisit for leaves/fringes
root = re.search(r'defaultPrim = "([^"]+)"', text).group(1)
open(os.path.join(out, aid, "src.usda"), "w").write(text)
open(os.path.join(out, aid, "wrap.usda"), "w").write(f'''#usda 1.0
(
    defaultPrim = "Root"
    metersPerUnit = 1
    upAxis = "Y"
)
def Xform "Root" (kind = "component")
{{
    float xformOp:rotateY = 180
    float xformOp:rotateX = -90
    uniform token[] xformOpOrder = ["xformOp:rotateY", "xformOp:rotateX"]
    def "{root}" (references = @./src.usda@</{root}>) {{}}
}}
''')
o = os.path.join(out, aid)
flat = run("usdcat", "--flatten", os.path.join(o, "wrap.usda"))
flat = flat.replace(f"@{os.path.realpath(o)}/textures/", "@./textures/").replace(f"@{o}/textures/", "@./textures/")
open(os.path.join(o, "flat.usda"), "w").write(flat)
run("usdcat", os.path.join(o, "flat.usda"), "-o", os.path.join(o, f"{aid}.usdc"))
z = os.path.join(out, f"{aid}.usdz")
if os.path.exists(z): os.remove(z)
subprocess.run(["usdzip", z, f"{aid}.usdc"] + [f"textures/{t}.jpg" for t in texs], cwd=o, check=True, capture_output=True)
chk = subprocess.run(["usdchecker", "--arkit", z], capture_output=True, text=True)
print(aid, os.path.getsize(z), "bytes;", "PASS" if chk.returncode == 0 else "FAIL", chk.stdout.strip().splitlines()[-1])
if chk.returncode: print(chk.stdout, chk.stderr)
