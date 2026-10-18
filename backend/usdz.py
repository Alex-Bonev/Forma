"""GLB (SAM 3D Objects output) -> USDZ that RealityKit loads, without usd-core (201 MB unzipped, too big for Vercel).

trimesh reads the GLB; we write the USDA layer as text and pack it with its textures into a USDZ, which is an
uncompressed zip whose files start on 64-byte boundaries, layer first. Checked with `usdchecker --arkit` and by
loading into RealityKit. trimesh already flips glTF's top-left UV origin to bottom-left, which is what USD's st uses.

Output is bounded so it fits Vercel's response cap as base64: meshes are decimated (keeping UVs) and textures
downscaled, halving the face budget until the package fits.
"""
import base64
import io
import json
import struct
import zipfile

import fast_simplification
import numpy as np
import trimesh
from PIL import Image

MAX_INPUT_FACES = 1_000_000  # refuse anything bigger outright: decimating it would take too long
START_FACES = 40_000
MIN_FACES = 2_500
MAX_TEXTURE = 1024
MAX_TEXTURE_PIXELS = 4096 * 4096  # per image, checked from the image header, before trimesh decodes it
MAX_TOTAL_TEXTURE_PIXELS = 2 * 4096 * 4096  # all images together
UNSUPPORTED_EXTENSIONS = {"KHR_draco_mesh_compression", "EXT_meshopt_compression"}  # trimesh can't decode these
MAX_USDZ = 3_200_000  # base64 of this is ~4.3 MB, under Vercel's 4.5 MB response cap


def glb_to_usdz(glb: bytes, max_bytes: int = MAX_USDZ) -> bytes:
    _check_glb(glb)
    meshes = _load(glb)
    faces = sum(len(m.faces) for m in meshes)
    budget = START_FACES
    while True:
        targets = _targets([len(m.faces) for m in meshes], budget)
        parts = [_decimate(m, t) for m, t in zip(meshes, targets)]
        out = _package(*_usda(parts)) if sum(len(m.faces) for m in parts) <= budget else None
        if out is not None and len(out) <= max_bytes:
            return out
        if budget <= MIN_FACES:
            raise ValueError(f"model too large to send at {budget} faces")
        budget //= 2


def _targets(counts: list[int], budget: int) -> list[int]:
    """Face target per part, summing to <= budget: each keeps min(its faces, 4), the rest is shared by size."""
    floors = [min(n, 4) for n in counts]
    if sum(floors) > budget:
        raise ValueError("model has too many parts")
    spare, extra = budget - sum(floors), sum(counts) - sum(floors)
    return [min(n, f + (spare * (n - f) // extra if extra else 0)) for n, f in zip(counts, floors)]


def _image_bytes(image: dict, views: list, glb: bytes, bin_start: int) -> bytes | None:
    """An image's encoded bytes: from a bufferView or a data: URI. Any other (external) uri is refused."""
    uri = image.get("uri")
    if isinstance(uri, str):
        if not uri.startswith("data:") or ";base64," not in uri:
            raise ValueError("GLB references an external texture")
        try:
            return base64.b64decode(uri.split(";base64,", 1)[1], validate=True)
        except ValueError:
            raise ValueError("GLB has an unreadable texture")
    index = image.get("bufferView")
    if not isinstance(index, int) or not 0 <= index < len(views) or not isinstance(views[index], dict):
        return None
    view = views[index]
    start = bin_start + int(view.get("byteOffset", 0))
    return bytes(glb[start:start + int(view.get("byteLength", 0))])


def _check_glb(glb: bytes) -> None:
    """Reads the GLB's JSON chunk before trimesh does: refuses compressed meshes and oversized textures."""
    if len(glb) < 20 or glb[:4] != b"glTF":
        raise ValueError("not a readable GLB")
    length, kind = struct.unpack_from("<I4s", glb, 12)
    if kind != b"JSON" or 20 + length > len(glb):
        raise ValueError("not a readable GLB")
    try:
        doc = json.loads(bytes(glb[20:20 + length]))
    except ValueError:
        raise ValueError("not a readable GLB")
    if not isinstance(doc, dict):
        raise ValueError("not a readable GLB")
    for buffer in doc.get("buffers", []):
        if isinstance(buffer, dict) and isinstance(buffer.get("uri"), str) and not buffer["uri"].startswith("data:"):
            raise ValueError("GLB references an external buffer")
    used = set(doc.get("extensionsUsed", [])) | set(doc.get("extensionsRequired", []))
    if used & UNSUPPORTED_EXTENSIONS:
        raise ValueError(f"compressed GLB not supported ({', '.join(sorted(used & UNSUPPORTED_EXTENSIONS))})")
    bin_start = 20 + length + 8  # BIN chunk header follows the JSON chunk
    views = doc.get("bufferViews", [])
    total = 0
    for image in doc.get("images", []):
        data = _image_bytes(image, views, glb, bin_start) if isinstance(image, dict) else None
        if data is None:
            continue
        try:
            w, h = Image.open(io.BytesIO(data)).size  # header only
        except Exception:
            raise ValueError("GLB has an unreadable texture")
        if w * h > MAX_TEXTURE_PIXELS:
            raise ValueError(f"texture too large ({w}x{h})")
        total += w * h
        if total > MAX_TOTAL_TEXTURE_PIXELS:
            raise ValueError("textures too large in total")


def _load(glb: bytes) -> list[trimesh.Trimesh]:
    try:
        scene = trimesh.load(io.BytesIO(glb), file_type="glb", force="scene")
    except Exception as e:
        raise ValueError(f"not a readable GLB: {e}") from e
    instances = [(geom, scene.graph.geometry_nodes.get(name, [])) for name, geom in scene.geometry.items()
                 if isinstance(geom, trimesh.Trimesh) and len(geom.faces)]
    faces = sum(len(geom.faces) * len(nodes) for geom, nodes in instances)  # instancing counts before any copy
    if faces > MAX_INPUT_FACES:
        raise ValueError(f"model too detailed ({faces} faces)")
    meshes = []
    for geom, nodes in instances:
        for node in nodes:  # bake node transforms so the USD is flat
            transform = scene.graph.get(node)[0]
            if len(nodes) == 1 and np.allclose(transform, np.eye(4)):
                m = geom
            else:
                m = geom.copy()
                m.apply_transform(transform)
            uv = getattr(m.visual, "uv", None)
            if not np.isfinite(m.vertices).all() or (uv is not None and not np.isfinite(uv).all()):
                raise ValueError("GLB has invalid (non-finite) coordinates")
            meshes.append(m)
    if not meshes:
        raise ValueError("GLB has no triangle meshes")
    return meshes


def _texture(m: trimesh.Trimesh) -> Image.Image | None:
    material = getattr(m.visual, "material", None)
    image = getattr(material, "baseColorTexture", None) or getattr(material, "image", None)
    return image if isinstance(image, Image.Image) and getattr(m.visual, "uv", None) is not None else None


def _decimate(m: trimesh.Trimesh, target: int) -> trimesh.Trimesh:
    """At most `target` faces. UVs follow each kept vertex, so the texture still maps."""
    if len(m.faces) <= target:
        return m
    points, faces = np.asarray(m.vertices, np.float64), np.asarray(m.faces, np.int32)
    # preserve_border keeps UV seams (split vertices form open borders) from tearing apart.
    _, _, collapses = fast_simplification.simplify(points, faces, target_count=target, return_collapses=True,
                                                   preserve_border=True)
    new_points, new_faces, mapping = fast_simplification.replay_simplification(points, faces, collapses)
    out = trimesh.Trimesh(new_points, new_faces, process=False)
    texture = _texture(m)
    if texture is not None:
        uv = np.zeros((len(new_points), 2))
        kept = np.unique(mapping, return_index=True)  # one original vertex per new vertex
        uv[kept[0]] = np.asarray(m.visual.uv)[kept[1]]
        out.visual = trimesh.visual.TextureVisuals(uv=uv, image=texture)
    else:
        out.visual = trimesh.visual.ColorVisuals(out, face_colors=_flat_color(m))
    return out


def _flat_color(m: trimesh.Trimesh) -> np.ndarray:
    """One RGB (0-1) for an untextured mesh: its average vertex or face color, else light gray."""
    try:
        colors = np.asarray(m.visual.vertex_colors)
        if len(colors):
            return colors[:, :3].mean(axis=0) / 255
    except Exception:
        pass
    return np.array([0.7, 0.7, 0.7])


def _normals(m: trimesh.Trimesh) -> np.ndarray:
    """Area-weighted vertex normals in numpy (trimesh's own needs scipy, else falls back to a slow path)."""
    v, f = np.asarray(m.vertices, np.float64), np.asarray(m.faces)
    face = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])  # length = 2 x area
    out = np.zeros_like(v)
    for k in range(3):
        np.add.at(out, f[:, k], face)
    length = np.linalg.norm(out, axis=1, keepdims=True)
    return np.divide(out, length, out=np.tile([0.0, 1.0, 0.0], (len(v), 1)), where=length > 0)


def _arr(rows: np.ndarray, fmt: str) -> str:
    """USDA array literal. One %-format over the whole array: per-row Python formatting took minutes on big meshes."""
    rows = np.asarray(rows)
    if not len(rows):
        return "[]"
    return "[" + (", ".join([fmt] * len(rows)) % tuple(rows.ravel().tolist())) + "]"


def _usda(meshes: list[trimesh.Trimesh]) -> tuple[str, dict[str, bytes]]:
    prims, mats, textures = [], [], {}
    for i, m in enumerate(meshes):
        texture = _texture(m)
        mat = f"</Root/Materials/mat{i}>"
        lines = [
            f'    def Mesh "mesh{i}" (prepend apiSchemas = ["MaterialBindingAPI"])', "    {",
            f"        point3f[] points = {_arr(m.vertices, '(%.7g, %.7g, %.7g)')}",
            f"        int[] faceVertexCounts = {_arr(np.full(len(m.faces), 3), '%d')}",
            f"        int[] faceVertexIndices = {_arr(m.faces.reshape(-1), '%d')}",
            f"        normal3f[] normals = {_arr(_normals(m), '(%.4g, %.4g, %.4g)')} (interpolation = \"vertex\")",
            '        uniform token subdivisionScheme = "none"',
            f"        rel material:binding = {mat}",
        ]
        if texture is not None:
            lines.append(f"        texCoord2f[] primvars:st = {_arr(m.visual.uv, '(%.7g, %.7g)')} (interpolation = \"vertex\")")
        lines.append("    }")
        prims.append("\n".join(lines))
        shader = [f'        def Material "mat{i}"', "        {",
                  f"            token outputs:surface.connect = </Root/Materials/mat{i}/pbr.outputs:surface>",
                  '            def Shader "pbr"', "            {", '                uniform token info:id = "UsdPreviewSurface"',
                  "                float inputs:roughness = 0.8", "                float inputs:metallic = 0"]
        if texture is not None:
            path = f"tex{i}.jpg"
            image = texture.convert("RGB")
            image.thumbnail((MAX_TEXTURE, MAX_TEXTURE))
            buf = io.BytesIO()
            image.save(buf, "JPEG", quality=85)
            textures[path] = buf.getvalue()
            shader += [f"                color3f inputs:diffuseColor.connect = </Root/Materials/mat{i}/tex.outputs:rgb>",
                       "                token outputs:surface", "            }",
                       '            def Shader "st"', "            {", '                uniform token info:id = "UsdPrimvarReader_float2"',
                       '                string inputs:varname = "st"', "                float2 outputs:result", "            }",
                       '            def Shader "tex"', "            {", '                uniform token info:id = "UsdUVTexture"',
                       f"                asset inputs:file = @{path}@",
                       f"                float2 inputs:st.connect = </Root/Materials/mat{i}/st.outputs:result>",
                       '                token inputs:wrapS = "repeat"', '                token inputs:wrapT = "repeat"',
                       "                float3 outputs:rgb", "            }"]
        else:
            color = np.asarray(m.visual.face_colors)[:, :3].mean(axis=0) / 255 if hasattr(m.visual, "face_colors") \
                else _flat_color(m)
            shader += ["                color3f inputs:diffuseColor = (%.4g, %.4g, %.4g)" % tuple(color),
                       "                token outputs:surface", "            }"]
        shader.append("        }")
        mats.append("\n".join(shader))
    usda = "\n".join(['#usda 1.0', '(', '    defaultPrim = "Root"', '    metersPerUnit = 1', '    upAxis = "Y"', ')', '',
                      'def Xform "Root"', '{', *prims, '    def Scope "Materials"', '    {', *mats, '    }', '}', ''])
    return usda, textures


def _package(usda: str, textures: dict[str, bytes]) -> bytes:
    """USDZ = uncompressed zip, every file's data 64-byte aligned, the layer first."""
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for name, data in {"model.usda": usda.encode(), **textures}.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            header = 30 + len(name.encode())  # local file header + name, then the extra field
            pad = (-(out.tell() + header + 4)) % 64
            info.extra = struct.pack("<HH", 0x1986, pad) + b"\0" * pad
            z.writestr(info, data)
    return out.getvalue()
