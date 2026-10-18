import io
import os
os.environ["APP_SHARED_SECRET"] = "s"
import httpx
from fastapi.testclient import TestClient
from PIL import Image
import main
from main import app

c = TestClient(app)
H = {"X-App-Secret": "s"}


def jpeg(w=600, h=900):
    buf = io.BytesIO()
    Image.new("RGB", (w, h)).save(buf, "JPEG")
    return buf.getvalue()


def fake_provider(monkeypatch, handler):
    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "IMAGE_API_KEY", "k")
    monkeypatch.setattr(main, "SHOPPING_API_KEY", "k")
    monkeypatch.setattr(main, "http", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler)))


def test_flow():
    assert c.get("/health").status_code == 401
    assert c.get("/health", headers=H).json()["mock"] is True
    r = c.post("/render", headers=H, files={"image": ("a.jpg", b"img")}, data={"prompt": "p"})
    assert r.json()["image_base64"] == "aW1n"
    style = c.post("/vibe/analyze", headers=H, files={"image": ("a.jpg", b"img")}).json()
    assert len(c.post("/vibe/products", headers=H, json=style).json()["products"]) == 3
    big = c.post("/render", headers=H, files={"image": ("a.jpg", b"x" * (4 * 1024 * 1024 + 1))}, data={"prompt": "p"})
    assert big.status_code == 413


def fake_gemini(monkeypatch, create):
    from types import SimpleNamespace as NS
    monkeypatch.setattr(main, "gemini", lambda: NS(aio=NS(interactions=NS(create=create))))


def test_render_provider(monkeypatch):
    sent = {}

    async def create(**kw):
        sent.update(kw)
        return type("I", (), {"output_image": type("O", (), {"data": "out"})()})()

    fake_provider(monkeypatch, None)
    fake_gemini(monkeypatch, create)
    r = c.post("/render", headers=H, files={"image": ("a.jpg", jpeg())}, data={"prompt": "cozy"})
    assert r.json() == {"image_base64": "out"}
    assert sent["response_format"]["aspect_ratio"] == "2:3"  # portrait in, portrait out
    assert "Style: cozy" in sent["input"][0]["text"]


def test_render_layout_structure_and_view(monkeypatch):
    sent = {}

    async def create(**kw):
        sent.update(kw)
        return type("I", (), {"output_image": type("O", (), {"data": "out"})()})()

    fake_provider(monkeypatch, None)
    fake_gemini(monkeypatch, create)
    r = c.post("/render", headers=H, data={"layout": "sofa: blue block", "view": "interior"},
               files={"image": ("a.jpg", jpeg()), "structure": ("s.png", jpeg(), "image/png")})
    assert r.status_code == 200
    text = sent["input"][0]["text"]
    assert "interior photograph" in text and "sofa: blue block" in text and "Image 2 is a structure map" in text
    assert [p["mime_type"] for p in sent["input"][1:]] == ["image/jpeg", "image/png"]  # snapshot first, then map
    bad = c.post("/render", headers=H, data={"view": "fisheye"}, files={"image": ("a.jpg", jpeg())})
    assert bad.status_code == 422


def test_render_image_numbering():
    assert "Image 2 is only a style reference" in main.render_prompt("cutaway", "", "", False, True)
    both = main.render_prompt("cutaway", "", "", True, True)
    assert "Image 2 is a structure map" in both and "Image 3 is only a style reference" in both
    assert "listed in the layout" not in both  # no layout, no legend promised


def test_render_combined_upload_cap():
    half = b"x" * (2 * 1024 * 1024 + 1)
    r = c.post("/render", headers=H, files={"image": ("a.jpg", half), "structure": ("s.png", half)})
    assert r.status_code == 413  # enforced in mock mode too


def test_render_provider_error(monkeypatch):
    async def create(**kw):
        raise RuntimeError("bad key")

    fake_provider(monkeypatch, None)
    fake_gemini(monkeypatch, create)
    r = c.post("/render", headers=H, files={"image": ("a.jpg", jpeg())})
    assert r.status_code == 502


def test_products_dedup(monkeypatch):
    item = {"title": "Lamp", "price": "$5", "thumbnail": "t", "product_link": "https://x/1", "source": "S"}
    fake_provider(monkeypatch, lambda req: httpx.Response(200, json={"shopping_results": [item]}))
    products = c.post("/vibe/products", headers=H, json=main.MOCK_STYLE.model_dump()).json()["products"]
    assert [p["product_url"] for p in products] == ["https://x/1"]


def test_non_ascii_secret_is_401():
    assert c.get("/health", headers={"X-App-Secret": "é".encode("latin-1")}).status_code == 401


def test_mock_products_have_unique_urls():
    products = c.post("/vibe/products", headers=H, json=main.MOCK_STYLE.model_dump()).json()["products"]
    assert len({p["product_url"] for p in products}) == len(products)


def test_products_provider_down(monkeypatch):
    fake_provider(monkeypatch, lambda req: httpx.Response(401, json={"error": "bad key"}))
    assert c.post("/vibe/products", headers=H, json=main.MOCK_STYLE.model_dump()).status_code == 502
