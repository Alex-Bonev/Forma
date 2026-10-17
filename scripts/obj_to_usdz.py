#!/usr/bin/env python3
"""Convert Kenney Furniture Kit OBJ (CC0, kenney.nl/assets/furniture-kit) to USDZ, one mesh per material.

ModelIO's OBJ->USD export collapses submesh materials onto one binding, so this writes USDA directly.
  scripts/obj_to_usdz.py "<kit>/Models/OBJ format" RoomVibe/Resources/DemoData/Furniture
"""
import subprocess, sys, tempfile
from pathlib import Path

# RoomPlan CapturedRoom.Object.Category (+ variants, + catalog-only items) -> Kenney model.
# fireplace has no match (renders as a box).
MAPPING = {
    "storage": "bookcaseClosedWide", "refrigerator": "kitchenFridgeLarge", "stove": "kitchenStove",
    "bed": "bedDouble", "sink": "kitchenSink", "washerDryer": "washerDryerStacked", "toilet": "toilet",
    "bathtub": "bathtub", "oven": "kitchenStoveElectric", "dishwasher": "kitchenCabinetDrawer",
    "table": "table", "sofa": "loungeSofa", "chair": "chairCushion", "television": "televisionModern",
    "stairs": "stairs",
    # Variants chosen from RoomPlan attributes / size (see RoomBuilder.furnitureModel).
    "sofa_corner": "loungeSofaCorner", "sofa_single": "loungeChair", "sofa_long": "loungeSofaLong",
    "table_coffee": "tableCoffee", "table_round": "tableRound",
    "chair_swivel": "chairDesk", "chair_stool": "stoolBar", "chair_arm": "loungeDesignChair",
    "storage_shelf": "bookcaseOpen", "storage_cabinet": "bookcaseClosedDoors", "storage_low": "cabinetTelevision",
    "plant": "pottedPlant", "lamp": "lampSquareFloor", "rug": "rugRectangle", "desk": "desk",
    "bench": "bench", "sideTable": "sideTable", "trashcan": "trashcan", "box": "cardboardBoxClosed",
}


def parse_mtl(path):
    colors, name = {}, None
    for line in path.read_text().splitlines():
        p = line.split()
        if p[:1] == ["newmtl"]:
            name = p[1]
        elif p[:1] == ["Kd"] and name:
            colors[name] = tuple(float(x) for x in p[1:4])
    return colors


def parse_obj(path):
    v, vn, groups, mat = [], [], {}, "default"
    for line in path.read_text().splitlines():
        p = line.split()
        if not p:
            continue
        if p[0] == "v":
            v.append(tuple(float(x) for x in p[1:4]))
        elif p[0] == "vn":
            vn.append(tuple(float(x) for x in p[1:4]))
        elif p[0] == "usemtl":
            mat = p[1]
        elif p[0] == "f":
            # "v/vt/vn" | "v//vn" | "v"; indices are 1-based (negative = relative)
            face = []
            for tok in p[1:]:
                parts = tok.split("/")
                vi = int(parts[0]); vi = vi - 1 if vi > 0 else len(v) + vi
                ni = int(parts[2]) if len(parts) > 2 and parts[2] else None
                ni = (ni - 1 if ni > 0 else len(vn) + ni) if ni is not None else None
                face.append((vi, ni))
            groups.setdefault(mat, []).append(face)
    return v, vn, groups


def fmt(t):
    return "(" + ", ".join(f"{x:.6g}" for x in t) + ")"


def to_usda(obj, colors, name):
    v, vn, groups = parse_obj(obj)
    out = [f'#usda 1.0\n(\n    defaultPrim = "{name}"\n    metersPerUnit = 1\n    upAxis = "Y"\n)\n',
           f'def Xform "{name}"\n{{']
    for i, (mat, faces) in enumerate(groups.items()):
        used = sorted({vi for f in faces for vi, _ in f})
        remap = {old: new for new, old in enumerate(used)}
        counts = [len(f) for f in faces]
        idx = [remap[vi] for f in faces for vi, _ in f]
        has_n = all(ni is not None for f in faces for _, ni in f)
        out.append(f'    def Mesh "part{i}" (\n        prepend apiSchemas = ["MaterialBindingAPI"]\n    )\n    {{')
        out.append(f'        int[] faceVertexCounts = [{", ".join(map(str, counts))}]')
        out.append(f'        int[] faceVertexIndices = [{", ".join(map(str, idx))}]')
        out.append(f'        point3f[] points = [{", ".join(fmt(v[k]) for k in used)}]')
        if has_n:
            out.append(f'        normal3f[] normals = [{", ".join(fmt(vn[ni]) for f in faces for _, ni in f)}] (\n'
                       '            interpolation = "faceVarying"\n        )')
        out.append('        uniform token subdivisionScheme = "none"')
        out.append(f'        rel material:binding = </{name}/Materials/m{i}>\n    }}')
    out.append('    def Scope "Materials"\n    {')
    for i, mat in enumerate(groups):
        c = colors.get(mat, (0.8, 0.8, 0.8))
        out.append(f'''        def Material "m{i}"
        {{
            token outputs:surface.connect = </{name}/Materials/m{i}/s.outputs:surface>
            def Shader "s"
            {{
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = {fmt(c)}
                float inputs:roughness = 0.8
                token outputs:surface
            }}
        }}''')
    out.append("    }\n}\n")
    return "\n".join(out)


def main():
    src, dst = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
    dst.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for category, model in MAPPING.items():
            obj = src / f"{model}.obj"
            colors = parse_mtl(src / f"{model}.mtl")
            usda = Path(tmp) / f"{category}.usda"
            usda.write_text(to_usda(obj, colors, category))
            out = dst / f"{category}.usdz"
            out.unlink(missing_ok=True)
            subprocess.run(["usdzip", str(out), usda.name], cwd=tmp, check=True, capture_output=True)
            print(category, "<-", model)


if __name__ == "__main__":
    main()
