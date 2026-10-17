import os
os.environ["APP_SHARED_SECRET"] = "s"
from fastapi.testclient import TestClient
from main import app

c = TestClient(app)
H = {"X-App-Secret": "s"}

def test_flow():
    assert c.get("/health").status_code == 401
    assert c.get("/health", headers=H).json()["mock"] is True
    r = c.post("/render", headers=H, files={"image": ("a.jpg", b"img")}, data={"prompt": "p"})
    assert r.json()["image_base64"] == "aW1n"
    style = c.post("/vibe/analyze", headers=H, files={"image": ("a.jpg", b"img")}).json()
    assert len(c.post("/vibe/products", headers=H, json=style).json()["products"]) == 3
    big = c.post("/render", headers=H, files={"image": ("a.jpg", b"x" * (4 * 1024 * 1024 + 1))}, data={"prompt": "p"})
    assert big.status_code == 413
