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


def test_render_provider(monkeypatch):
    sent = {}

    def handler(req):
        sent["body"] = req.content
        return httpx.Response(200, json={"data": [{"b64_json": "out"}]})

    fake_provider(monkeypatch, handler)
    r = c.post("/render", headers=H, files={"image": ("a.jpg", jpeg())}, data={"prompt": "cozy"})
    assert r.json() == {"image_base64": "out"}
    assert b"1024x1536" in sent["body"] and b"Style: cozy" in sent["body"]  # portrait in, portrait out


def test_render_provider_error(monkeypatch):
    fake_provider(monkeypatch, lambda req: httpx.Response(400, json={"error": "nope"}))
    r = c.post("/render", headers=H, files={"image": ("a.jpg", jpeg())})
    assert r.status_code == 502


def test_products_dedup(monkeypatch):
    item = {"title": "Lamp", "price": "$5", "thumbnail": "t", "product_link": "https://x/1", "source": "S"}
    fake_provider(monkeypatch, lambda req: httpx.Response(200, json={"shopping_results": [item]}))
    products = c.post("/vibe/products", headers=H, json=main.MOCK_STYLE.model_dump()).json()["products"]
    assert [p["product_url"] for p in products] == ["https://x/1"]
