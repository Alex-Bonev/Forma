import base64
import io
import json
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
    assert len(c.post("/vibe/products", headers=H, json=style).json()["products"]) == 4
    big = c.post("/render", headers=H, files={"image": ("a.jpg", b"x" * (main.MAX_UPLOAD + 1))}, data={"prompt": "p"})
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


def test_render_scan_photos(monkeypatch):
    sent = {}

    async def create(**kw):
        sent.update(kw)
        return type("I", (), {"output_image": type("O", (), {"data": "out"})()})()

    fake_provider(monkeypatch, None)
    fake_gemini(monkeypatch, create)
    files = [("image", ("a.jpg", jpeg())), ("structure", ("s.png", jpeg(), "image/png"))]
    files += [("photos", (f"p{i}.jpg", jpeg(300, 200), "image/jpeg")) for i in range(5)]
    r = c.post("/render", headers=H, files=files)
    assert r.status_code == 200
    text = sent["input"][0]["text"]
    assert "Images 3 to 5 are real photos" in text and "Add nothing that is not in image 1" in text
    assert len(sent["input"]) == 1 + 2 + 3  # prompt, snapshot + map, photos capped at 3
    assert "Be faithful" not in main.render_prompt("cutaway", "", "japandi", False, False)  # vibe restyle
    assert "Be faithful" not in main.render_prompt("cutaway", "", "", False, True)
    one = main.render_prompt("cutaway", "", "", False, False, 1)
    assert "Image 2 is a real photo" in one


def test_render_combined_upload_cap():
    half = b"x" * (main.MAX_UPLOAD // 2 + 1)
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


def test_analyze_inputs():
    assert c.post("/vibe/analyze", headers=H).status_code == 400
    assert c.post("/vibe/analyze", headers=H, data={"prompt": "  "}).status_code == 400
    assert c.post("/vibe/analyze", headers=H, data={"prompt": "x" * 1001}).status_code == 400
    text = c.post("/vibe/analyze", headers=H, data={"prompt": "cozy nook under $800"}).json()
    assert text["budget_usd"] == 800
    assert sum(it["max_price_usd"] for it in text["shopping_list"]) <= 800
    both = c.post("/vibe/analyze", headers=H, files={"image": ("a.jpg", jpeg())}, data={"prompt": "japandi"}).json()
    assert both["budget_usd"] is None and all(it["max_price_usd"] is None for it in both["shopping_list"])
    old = {k: v for k, v in main.MOCK_STYLE.model_dump().items() if k not in ("room_type", "budget_usd", "shopping_list")}
    assert c.post("/vibe/products", headers=H, json=old).status_code == 200  # old app's Style still accepted


def test_analyze_provider(monkeypatch):
    sent = {}

    async def parse(**kw):
        sent.update(kw)
        style = main.MOCK_STYLE.model_copy(deep=True, update={"budget_usd": 1000})
        style.shopping_list[0].category = "spaceship"
        style.shopping_list[0].max_price_usd = 900
        style.shopping_list[1].max_price_usd = 900
        return type("M", (), {"stop_reason": "end_turn", "parsed_output": style})()

    from types import SimpleNamespace as NS
    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "LLM_API_KEY", "k")
    monkeypatch.setattr(main.anthropic, "AsyncAnthropic", lambda **kw: NS(beta=NS(messages=NS(parse=parse))))
    img = c.post("/vibe/analyze", headers=H, files={"image": ("a.png", jpeg(), "image/png")}, data={"prompt": "boho"})
    assert img.status_code == 200
    content = sent["messages"][0]["content"]
    assert [p["type"] for p in content] == ["image", "text", "text", "text"]
    assert content[0]["source"]["media_type"] == "image/png" and content[0]["source"]["data"]
    assert c.post("/vibe/analyze", headers=H, files={"image": ("", b"")}).status_code == 400  # empty part
    r = c.post("/vibe/analyze", headers=H, data={"prompt": "boho, $1k"}).json()
    content = sent["messages"][0]["content"]
    assert [p["type"] for p in content] == ["text", "text"]  # no image block for a text-only request
    assert "boho, $1k" in content[0]["text"] and "floor_lamp" in content[1]["text"]
    assert r["shopping_list"][0]["category"] == "decor"
    assert sum(it["max_price_usd"] for it in r["shopping_list"]) <= 1000


def test_parse_budget():
    assert main.parse_budget("under $1,200 please") == 1200
    assert main.parse_budget("about $1.5k total") == 1500
    assert main.parse_budget("$2k") == 2000
    assert main.parse_budget("a cozy 2 bedroom") is None
    assert main.parse_budget("3k sq ft loft") is None  # no $, not a budget


def test_clean_style_budget_shares():
    def style(budget, shares):
        items = [main.ShoppingItem(category="chair", query=f"q{i}", max_price_usd=s) for i, s in enumerate(shares)]
        return main.clean_style(main.MOCK_STYLE.model_copy(update={"budget_usd": budget, "shopping_list": items}))

    assert [it.max_price_usd for it in style(1000, [300, None, None]).shopping_list] == [300, 350, 350]
    assert [it.max_price_usd for it in style(600, [500, 500, None]).shopping_list] == [200, 200, 200]
    assert [it.max_price_usd for it in style(None, [500, 500]).shopping_list] == [None, None]
    assert len(style(None, [1] * 9).shopping_list) == 6
    assert sum(it.max_price_usd for it in style(0.75, [None, None]).shopping_list) <= 0.75  # floors cents
    fallback = main.clean_style(main.MOCK_STYLE.model_copy(update={"shopping_list": []}))
    assert [it.query for it in fallback.shopping_list] == main.MOCK_STYLE.search_queries
    assert main.MOCK_STYLE.shopping_list[0].category == "sofa"  # input not mutated


def shop_request(budget=None):
    return {"style": main.MOCK_STYLE.model_dump(), "budget_usd": budget}


def test_shop_mock_streams_then_picks(monkeypatch):
    start = c.post("/vibe/shop", headers=H, json=shop_request(500)).json()
    assert [it["category"] for it in start["items"]] == ["sofa", "round_table", "armchair", "floor_lamp"]
    first = c.get(f"/vibe/shop/{start['job']}", headers=H).json()
    assert not first["done"] and [it["status"] for it in first["items"]] == ["done", "running", "done", "running"]
    assert "chosen" not in first
    monkeypatch.setattr(main.time, "time", lambda: 10**10)  # later poll
    last = c.get(f"/vibe/shop/{start['job']}", headers=H).json()
    assert last["done"] and last["budget_usd"] == 500
    assert 0 < last["total_usd"] <= 500 and len(last["chosen"]) >= 2
    product = last["items"][0]["products"][0]
    assert product["category"] == "sofa" and product["dimensions_cm"] == [80, 75, 80] and product["price_usd"] > 0


def test_shop_bad_job():
    assert c.get("/vibe/shop/not-a-job", headers=H).status_code == 400
    job = c.post("/vibe/shop", headers=H, json=shop_request()).json()["job"]
    body = job.split(".")[0]
    forged = main.encode_job({"items": [{"category": "sofa", "query": "q", "run": "../billing?x"}], "t": 0})
    assert c.get(f"/vibe/shop/{body}.{'0' * 32}", headers=H).status_code == 400  # tampered signature
    assert c.get(f"/vibe/shop/{forged}", headers=H).status_code == 400  # bad run id, even when signed


def test_allowed_url():
    assert main.allowed_url("https://www.ikea.com/p/1")
    for bad in ("http://ikea.com/p", "https://www.facebook.com/marketplace/item/1", "https://m.facebook.com/x",
                "https://fb.me/x", "javascript:alert(1)", "https://", "not a url", "https://facebook.com./x",
                "https://www.facebook.com./marketplace", "https://fb.me./x", "https://WWW.FaceBook.COM/x"):
        assert not main.allowed_url(bad), bad
    assert main.allowed_url("https://notfacebook.com/x")  # only facebook.com and its subdomains are blocked


def test_shop_provider(monkeypatch):
    created, runs = [], {}
    good = {"title": "Oak Table", "price_usd": 199.0, "image_url": "https://img/1.jpg",
            "product_url": "https://shop.example/oak", "retailer": "Shop", "width_cm": 90, "height_cm": 45}
    fb = {**good, "product_url": "https://www.facebook.com/marketplace/item/9"}
    pricey = {**good, "product_url": "https://shop.example/gold", "price_usd": 99999}
    inf = {**good, "product_url": "https://shop.example/inf", "price_usd": float("inf"), "depth_cm": float("nan")}

    def handler(req):
        assert req.headers["X-Browser-Use-API-Key"] == "bu"
        if req.method == "POST":
            body = json.loads(req.content)
            created.append(body)
            if "Find: rattan lounge chair" in body["task"]:
                return httpx.Response(500)  # this agent never starts
            return httpx.Response(200, json={"id": f"r{len(created)}", "status": "queued"})
        return httpx.Response(200, content=json.dumps(runs[req.url.path.rsplit("/", 1)[1]]))  # allows Infinity

    fake_provider(monkeypatch, handler)
    monkeypatch.setattr(main, "BROWSER_USE_API_KEY", "bu")
    r = c.post("/vibe/shop", headers=H, json=shop_request(1000))
    assert r.status_code == 200, r.text
    start = r.json()
    assert len(created) == 4 and created[0]["maxCostUsd"] == main.BROWSER_USE_MAX_COST
    assert "never facebook.com" in created[0]["task"] and "at most $" in created[0]["task"]
    assert created[0]["outputSchema"]["properties"]["products"]
    runs.update({"r1": {"status": "completed", "output": {"products": [fb, good, {"title": "junk"}]}},
                 "r2": {"status": "running"}, "r4": {"status": "completed", "output": {"products": [good, pricey, inf]}}})
    poll = c.get(f"/vibe/shop/{start['job']}", headers=H).json()
    statuses = [it["status"] for it in poll["items"]]
    assert statuses == ["done", "running", "failed", "failed"]  # r4's only valid product is a duplicate of r1's
    assert [p["product_url"] for p in poll["items"][0]["products"]] == ["https://shop.example/oak"]
    assert poll["items"][0]["products"][0]["dimensions_cm"] is None  # depth missing
    runs["r2"] = {"status": "failed"}
    done = c.get(f"/vibe/shop/{start['job']}", headers=H).json()
    assert done["done"] and done["chosen"] == ["https://shop.example/oak"] and done["total_usd"] == 199


def test_shop_provider_timeout_and_down(monkeypatch):
    fake_provider(monkeypatch, lambda req: httpx.Response(200, json={"id": "r1"}) if req.method == "POST"
                  else httpx.Response(503))
    monkeypatch.setattr(main, "BROWSER_USE_API_KEY", "bu")
    job = c.post("/vibe/shop", headers=H, json=shop_request()).json()["job"]
    assert not c.get(f"/vibe/shop/{job}", headers=H).json()["done"]  # unreadable run: still running
    monkeypatch.setattr(main.time, "time", lambda: 10**10)
    assert {it["status"] for it in c.get(f"/vibe/shop/{job}", headers=H).json()["items"]} == {"failed"}
    fake_provider(monkeypatch, lambda req: httpx.Response(401))
    assert c.post("/vibe/shop", headers=H, json=shop_request()).status_code == 502
    assert c.get(f"/vibe/shop/{job}", headers=H).status_code == 502  # key revoked mid-job


def test_shop_ignores_non_finite_budget(monkeypatch):
    for bad in ("Infinity", "NaN", "-5"):
        body = json.dumps(shop_request()).replace('"budget_usd": null', f'"budget_usd": {bad}')
        start = c.post("/vibe/shop", headers={**H, "Content-Type": "application/json"}, content=body)
        assert start.status_code == 200, bad
        monkeypatch.setattr(main.time, "time", lambda: 10**10)
        done = c.get(f"/vibe/shop/{start.json()['job']}", headers=H).json()
        assert done["budget_usd"] is None and len(done["chosen"]) == 4  # no budget: first product of each item
        monkeypatch.undo()


def test_model3d_mock():
    assert c.post("/vibe/model3d", headers=H, json={"image_url": "http://x/a.jpg"}).status_code == 400
    rid = c.post("/vibe/model3d", headers=H, json={"image_url": "https://x/a.jpg", "category": "sofa"}).json()["request_id"]
    done = c.get(f"/vibe/model3d/{rid}", headers=H).json()
    assert done["status"] == "done" and base64.b64decode(done["usdz_base64"])[:2] == b"PK"
    assert c.get("/vibe/model3d/other", headers=H).status_code == 404


STATUS_URL = "https://queue.fal.run/fal-ai/sam-3/requests/abc-123/status"
RESULT_URL = "https://queue.fal.run/fal-ai/sam-3/requests/abc-123"
GLB_URL = "https://v3.fal.media/files/m.glb"


def fake_fal(monkeypatch, state, glb):
    seen = []

    def handler(req):
        url = str(req.url)
        seen.append((url, req.headers.get("Authorization")))
        if req.method == "POST":
            assert req.headers["Authorization"] == "Key fk" and url == "https://queue.fal.run/fal-ai/sam-3/3d-objects"
            state["sent"] = json.loads(req.content)
            return httpx.Response(200, json={"request_id": "abc-123", "status_url": STATUS_URL, "response_url": RESULT_URL})
        if url == STATUS_URL:
            return httpx.Response(200, json={k: v for k, v in state.items() if k in ("status", "error")})
        if url == RESULT_URL:
            return httpx.Response(200, json={"model_glb": {"url": state.get("glb", GLB_URL)}})
        if url == GLB_URL:
            return httpx.Response(200, content=glb)
        return httpx.Response(404)

    fake_provider(monkeypatch, handler)
    monkeypatch.setattr(main, "FAL_KEY", "fk")
    monkeypatch.setattr(main, "check_public_host", lambda url: None)  # no DNS in tests
    return seen


def test_model3d_provider(monkeypatch):
    import trimesh
    state = {"status": "IN_PROGRESS"}
    seen = fake_fal(monkeypatch, state, trimesh.creation.box().export(file_type="glb"))
    rid = c.post("/vibe/model3d", headers=H, json={"image_url": "https://x/a.jpg", "category": "floor_lamp"}).json()["request_id"]
    assert state["sent"]["prompt"] == "floor lamp" and state["sent"]["export_textured_glb"] is True
    assert main.decode_model_job(rid) == (STATUS_URL, RESULT_URL)  # fal's own links, carried in the signed id
    assert c.get(f"/vibe/model3d/{rid}", headers=H).json() == {"status": "running"}
    state["status"] = "COMPLETED"
    done = c.get(f"/vibe/model3d/{rid}", headers=H).json()
    assert done["status"] == "done" and base64.b64decode(done["usdz_base64"])[:2] == b"PK"
    assert (GLB_URL, None) in seen  # the API key never goes to the CDN
    for bad in ("http://v3.fal.media/m.glb", "https://evil.example/m.glb"):
        state["glb"] = bad
        assert c.get(f"/vibe/model3d/{rid}", headers=H).json()["status"] == "failed"
    state.pop("glb")
    monkeypatch.setattr(main, "MAX_GLB", 100)
    assert c.get(f"/vibe/model3d/{rid}", headers=H).json() == {"status": "failed", "error": "model file too large"}
    state.update(error="segmentation failed")
    assert c.get(f"/vibe/model3d/{rid}", headers=H).json() == {"status": "failed", "error": "segmentation failed"}
    fake_provider(monkeypatch, lambda req: httpx.Response(401))
    assert c.get(f"/vibe/model3d/{rid}", headers=H).status_code == 502
    assert c.post("/vibe/model3d", headers=H, json={"image_url": "https://x/a.jpg"}).status_code == 502
    fake_provider(monkeypatch, lambda req: httpx.Response(200, content=b"<html>"))
    assert c.post("/vibe/model3d", headers=H, json={"image_url": "https://x/a.jpg"}).status_code == 502
    assert c.get(f"/vibe/model3d/{rid}", headers=H).status_code == 502


def test_model3d_token_tampering(monkeypatch):
    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "FAL_KEY", "fk")
    rid = main.encode_model_job(STATUS_URL, RESULT_URL)
    body = rid.split(".")[0]
    assert c.get(f"/vibe/model3d/{body}.{'0' * 32}", headers=H).status_code == 400
    forged = main.encode_model_job("https://evil.example/status", RESULT_URL)  # signed, but not fal
    assert c.get(f"/vibe/model3d/{forged}", headers=H).status_code == 400
    assert c.get("/vibe/model3d/mock-model", headers=H).status_code == 400
    shop = main.encode_job({"items": [], "t": 0})  # a shopping token is not a model token
    assert c.get(f"/vibe/model3d/{shop}", headers=H).status_code == 400


def test_check_public_host():
    import pytest
    for bad in ("https://127.0.0.1/m.glb", "https://[::1]/m.glb", "https://localhost/m.glb"):
        with pytest.raises(ValueError):
            main.check_public_host(bad)


def test_profile_inputs():
    assert c.post("/vibe/profile", headers=H).status_code == 422
    many = [("images", ("a.jpg", jpeg(40, 40)))] * (main.MAX_VIBE_IMAGES + 1)
    assert c.post("/vibe/profile", headers=H, files=many).status_code == 400
    assert c.post("/vibe/profile", headers=H, files=[("images", ("a.txt", b"hello"))]).status_code == 415
    big = c.post("/vibe/profile", headers=H, files=[("images", ("a.jpg", b"x" * (main.MAX_UPLOAD + 1)))])
    assert big.status_code == 413
    ok = c.post("/vibe/profile", headers=H, files=[("images", ("a.jpg", jpeg(40, 40)))] * 3)
    assert ok.status_code == 200 and ok.json()["name"] == "Enchanted Cottage"


def test_profile_provider(monkeypatch):
    sent = {}

    async def parse(**kw):
        sent.update(kw)
        p = main.MOCK_PROFILE.model_copy(deep=True, update={"name": "  Moss  ", "styles": [" a ", "a", ""]})
        p.colors.append(main.VibeColor(name="bad", hex="green"))
        return type("M", (), {"stop_reason": "end_turn", "parsed_output": p})()

    from types import SimpleNamespace as NS
    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "LLM_API_KEY", "k")
    monkeypatch.setattr(main.anthropic, "AsyncAnthropic", lambda **kw: NS(beta=NS(messages=NS(parse=parse))))
    files = [("images", ("a.jpg", jpeg(40, 40))), ("images", ("b.png", b"\x89PNG\r\n\x1a\n", "image/png"))]
    assert c.post("/vibe/profile", headers=H, files=files).status_code == 415  # truncated PNG is not an image
    r = c.post("/vibe/profile", headers=H, files=[("images", ("a.jpg", jpeg(40, 40)))] * 2)
    assert r.status_code == 200
    # One model call carries every image plus the prompt.
    assert [p["type"] for p in sent["messages"][0]["content"]] == ["image", "image", "text"]
    body = r.json()
    assert body["name"] == "Moss" and body["styles"] == ["a"] and len(body["colors"]) == 2


def test_profile_description_length(monkeypatch):
    lo, hi = main.DESC_WORDS
    assert lo <= len(main.MOCK_PROFILE.description.split()) <= hi
    test_profile_provider(monkeypatch)  # sets the fake provider; its description is in range
    assert c.post("/vibe/profile", headers=H, files=[("images", ("a.jpg", jpeg(40, 40)))]).status_code == 200
    short = main.MOCK_PROFILE.model_copy(update={"description": "too short"})

    async def parse(**kw):
        return type("M", (), {"stop_reason": "end_turn", "parsed_output": short})()

    from types import SimpleNamespace as NS
    monkeypatch.setattr(main.anthropic, "AsyncAnthropic", lambda **kw: NS(beta=NS(messages=NS(parse=parse))))
    r = c.post("/vibe/profile", headers=H, files=[("images", ("a.jpg", jpeg(40, 40)))])
    assert r.status_code == 502 and "2-word" in r.text
