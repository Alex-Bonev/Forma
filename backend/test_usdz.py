import io
import shutil
import subprocess
import zipfile

import numpy as np
import pytest
import trimesh
from PIL import Image

import usdz


def textured_glb(subdivisions=2, size=64):
    m = trimesh.creation.icosphere(subdivisions=subdivisions)
    uv = np.stack([np.arctan2(m.vertices[:, 1], m.vertices[:, 0]) / (2 * np.pi) + 0.5, m.vertices[:, 2] * 0.5 + 0.5], 1)
    image = Image.new("RGB", (size, size), (200, 100, 50))
    m.visual = trimesh.visual.TextureVisuals(uv=uv, material=trimesh.visual.material.PBRMaterial(baseColorTexture=image))
    return m.export(file_type="glb")


def test_textured_package_layout(tmp_path):
    out = usdz.glb_to_usdz(textured_glb(size=2048))
    z = zipfile.ZipFile(io.BytesIO(out))
    names = [i.filename for i in z.infolist()]
    assert names[0] == "model.usda" and names[1:] == ["tex0.jpg"]
    for info in z.infolist():
        assert info.compress_type == zipfile.ZIP_STORED
        data_start = info.header_offset + 30 + len(info.filename) + len(info.extra)
        assert data_start % 64 == 0, info.filename
    layer = z.read("model.usda").decode()
    assert "UsdUVTexture" in layer and "primvars:st" in layer and 'upAxis = "Y"' in layer
    assert max(Image.open(io.BytesIO(z.read("tex0.jpg"))).size) <= usdz.MAX_TEXTURE
    if shutil.which("usdchecker"):
        path = tmp_path / "m.usdz"
        path.write_bytes(out)
        result = subprocess.run(["usdchecker", "--arkit", str(path)], capture_output=True, text=True)
        assert "Success!" in result.stdout + result.stderr


def test_untextured_gets_flat_color():
    glb = trimesh.creation.box(extents=[0.5, 0.4, 0.3]).export(file_type="glb")
    z = zipfile.ZipFile(io.BytesIO(usdz.glb_to_usdz(glb)))
    layer = z.read("model.usda").decode()
    assert [i.filename for i in z.infolist()] == ["model.usda"]
    assert "inputs:diffuseColor = (" in layer and "UsdUVTexture" not in layer


def test_dense_mesh_is_decimated_with_uvs():
    out = usdz.glb_to_usdz(textured_glb(subdivisions=6))  # 81,920 faces
    layer = zipfile.ZipFile(io.BytesIO(out)).read("model.usda").decode()
    counts = layer.split("faceVertexCounts = [")[1].split("]")[0].count("3")
    assert counts <= usdz.START_FACES and "primvars:st" in layer


def test_too_large_raises():
    with pytest.raises(ValueError, match="too large"):
        usdz.glb_to_usdz(textured_glb(subdivisions=4), max_bytes=1000)
    with pytest.raises(ValueError, match="not a readable GLB"):
        usdz.glb_to_usdz(b"not a glb")


def glb_with_json(doc: dict, bin_chunk: bytes = b"") -> bytes:
    import json
    import struct
    j = json.dumps(doc).encode()
    j += b" " * (-len(j) % 4)
    body = struct.pack("<I4s", len(j), b"JSON") + j
    if bin_chunk:
        bin_chunk += b"\0" * (-len(bin_chunk) % 4)
        body += struct.pack("<I4s", len(bin_chunk), b"BIN\0") + bin_chunk
    return struct.pack("<4sII", b"glTF", 2, 12 + len(body)) + body


def test_refuses_compressed_and_huge_textures():
    with pytest.raises(ValueError, match="compressed"):
        usdz.glb_to_usdz(glb_with_json({"asset": {"version": "2.0"}, "extensionsRequired": ["KHR_draco_mesh_compression"]}))
    big = io.BytesIO()
    Image.new("L", (5000, 4000)).save(big, "PNG")  # header says 20 MP; never decoded
    png = big.getvalue()
    doc = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(png)}],
           "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(png)}],
           "images": [{"bufferView": 0, "mimeType": "image/png"}]}
    with pytest.raises(ValueError, match="texture too large"):
        usdz.glb_to_usdz(glb_with_json(doc, png))


def test_instancing_counts_toward_face_cap(monkeypatch):
    scene = trimesh.Scene()
    sphere = trimesh.creation.icosphere(subdivisions=3)  # 1,280 faces
    for i in range(10):
        scene.add_geometry(sphere, geom_name="ball", node_name=f"n{i}",
                           transform=trimesh.transformations.translation_matrix([i, 0, 0]))
    glb = scene.export(file_type="glb")
    monkeypatch.setattr(usdz, "MAX_INPUT_FACES", 10_000)
    with pytest.raises(ValueError, match="too detailed"):
        usdz.glb_to_usdz(glb)
    monkeypatch.setattr(usdz, "MAX_INPUT_FACES", 20_000)
    layer = zipfile.ZipFile(io.BytesIO(usdz.glb_to_usdz(glb))).read("model.usda").decode()
    assert layer.count('def Mesh "') == 10 and "normal3f[] normals" in layer


def test_non_finite_and_face_budget(monkeypatch):
    m = trimesh.creation.box()
    m.vertices[0] = [np.nan, 0, 0]
    with pytest.raises(ValueError, match="non-finite"):
        usdz.glb_to_usdz(m.export(file_type="glb"))
    monkeypatch.setattr(usdz, "START_FACES", 3000)
    layer = zipfile.ZipFile(io.BytesIO(usdz.glb_to_usdz(textured_glb(subdivisions=5)))).read("model.usda").decode()
    indices = layer.split("faceVertexIndices = [")[1].split("]")[0].count(",") + 1
    assert indices // 3 <= 3000


def png_bytes(w, h):
    buf = io.BytesIO()
    Image.new("L", (w, h)).save(buf, "PNG")
    return buf.getvalue()


def test_data_uri_and_external_textures():
    import base64
    uri = "data:image/png;base64," + base64.b64encode(png_bytes(5000, 4000)).decode()
    with pytest.raises(ValueError, match="texture too large"):
        usdz.glb_to_usdz(glb_with_json({"asset": {"version": "2.0"}, "images": [{"uri": uri}]}))
    with pytest.raises(ValueError, match="external texture"):
        usdz.glb_to_usdz(glb_with_json({"asset": {"version": "2.0"}, "images": [{"uri": "https://x/t.png"}]}))
    with pytest.raises(ValueError, match="external buffer"):
        usdz.glb_to_usdz(glb_with_json({"asset": {"version": "2.0"}, "buffers": [{"uri": "/etc/passwd", "byteLength": 1}]}))


def test_total_texture_budget():
    import base64
    uri = "data:image/png;base64," + base64.b64encode(png_bytes(4096, 4096)).decode()  # each allowed alone
    with pytest.raises(ValueError, match="in total"):
        usdz.glb_to_usdz(glb_with_json({"asset": {"version": "2.0"}, "images": [{"uri": uri}] * 3}))


def test_non_dict_json_chunk():
    with pytest.raises(ValueError, match="not a readable GLB"):
        usdz.glb_to_usdz(glb_with_json([1, 2, 3]))


def test_tiny_parts_get_floors():
    assert usdz._targets([1, 2, 100_000], 1000) == [1, 2, 997]
    assert sum(usdz._targets([12] * 50 + [80_000], 2500)) <= 2500
    assert min(usdz._targets([12] * 50, 2500)) == 12  # small enough to keep whole
    with pytest.raises(ValueError, match="too many parts"):
        usdz._targets([12] * 700, 2500)
    scene = trimesh.Scene()
    scene.add_geometry(trimesh.creation.icosphere(subdivisions=6), node_name="big")  # 81,920 faces
    scene.add_geometry(trimesh.creation.box(), node_name="tiny")  # 12 faces
    layer = zipfile.ZipFile(io.BytesIO(usdz.glb_to_usdz(scene.export(file_type="glb")))).read("model.usda").decode()
    assert layer.count('def Mesh "') == 2
