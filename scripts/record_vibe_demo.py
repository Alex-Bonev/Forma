#!/usr/bin/env python3
"""Record one Vibe shopping run and bundle it as the app's offline demo result.

  backend/.venv/bin/python scripts/record_vibe_demo.py --placeholders            # local MOCK=1 backend on :8000
  RV_BASE_URL=http://127.0.0.1:8000 RV_SECRET=<APP_SHARED_SECRET> \\
      backend/.venv/bin/python scripts/record_vibe_demo.py                       # local MOCK=0 backend, real agents (minutes)

Calls /vibe/analyze, /vibe/shop, then polls until every agent is done. Writes
RoomVibe/Resources/DemoData/vibe_demo.json (prompt, style, final status) and vibe_demo_<n>.jpg product images,
referenced from the JSON as "bundle:vibe_demo_<n>.jpg". The URL and secret come from the environment only.
"""
import argparse, io, json, os, sys, time
from pathlib import Path

import httpx
from PIL import Image, ImageDraw

DEMO = Path(__file__).resolve().parent.parent / "RoomVibe/Resources/DemoData"
MAX_IMAGE_BYTES = 60_000

p = argparse.ArgumentParser()
p.add_argument("--prompt", default="Cozy japandi reading nook under $800")
p.add_argument("--placeholders", action="store_true", help="draw palette-colored images instead of downloading")
p.add_argument("--allow-partial", action="store_true", help="write even if some agents failed or nothing was chosen")
a = p.parse_args()

# Only these fields reach the bundle (whatever else the backend sends stays out of the app).
STYLE_KEYS = ("style_name", "palette", "materials", "furniture_types", "decor_items", "search_queries", "room_type",
              "budget_usd", "shopping_list")
SHOPPING_ITEM_KEYS = ("category", "query", "max_price_usd")
STATUS_KEYS = ("done", "budget_usd", "items", "chosen", "total_usd")
ITEM_KEYS = ("category", "query", "status", "products")
PRODUCT_KEYS = ("title", "price", "image_url", "product_url", "retailer", "price_usd", "category", "dimensions_cm")


def pick(d: dict, keys) -> dict:
    return {k: d[k] for k in keys if k in d}

base = os.environ.get("RV_BASE_URL", "http://127.0.0.1:8000").rstrip("/")
headers = {"X-App-Secret": os.environ["RV_SECRET"]} if os.environ.get("RV_SECRET") else {}
client = httpx.Client(base_url=base, headers=headers, timeout=120)


def ok(r: httpx.Response) -> dict:
    if r.status_code != 200:
        sys.exit(f"{r.request.method} {r.request.url.path}: {r.status_code} {r.text[:300]}")
    return r.json()


style = ok(client.post("/vibe/analyze", data={"prompt": a.prompt}))
job = ok(client.post("/vibe/shop", json={"style": style}))["job"]
deadline = time.time() + 10 * 60
while True:
    status = ok(client.get(f"/vibe/shop/{job}"))
    print("items:", [it["status"] for it in status["items"]])
    if status["done"]:
        break
    if time.time() > deadline:
        sys.exit("agents still running after 10 minutes")
    time.sleep(4)


incomplete = [it["query"] for it in status["items"] if it["status"] != "done" or not it["products"]]
if (incomplete or not status.get("chosen")) and not a.allow_partial:
    sys.exit(f"not writing a partial result (failed or empty: {incomplete}, chosen: {len(status.get('chosen') or [])}); "
             "rerun, or pass --allow-partial")

style = pick(style, STYLE_KEYS)
style["shopping_list"] = [pick(it, SHOPPING_ITEM_KEYS) for it in style.get("shopping_list", [])]
status = pick(status, STATUS_KEYS)
status["items"] = [pick(it, ITEM_KEYS) for it in status["items"]]
for it in status["items"]:
    it["products"] = [pick(p, PRODUCT_KEYS) for p in it["products"]]


def jpeg(image: Image.Image) -> bytes:
    image = image.convert("RGB")
    image.thumbnail((400, 400))
    for quality in (75, 60, 45, 30):
        buf = io.BytesIO()
        image.save(buf, "JPEG", quality=quality)
        if buf.tell() <= MAX_IMAGE_BYTES:
            return buf.getvalue()
    return buf.getvalue()


def placeholder(n: int, title: str) -> bytes:
    palette = style.get("palette") or ["#B59F84"]
    image = Image.new("RGB", (400, 400), palette[n % len(palette)])
    ImageDraw.Draw(image).text((20, 360), title[:40], fill="white" if n % len(palette) > 1 else "black")
    return jpeg(image)


for old in DEMO.glob("vibe_demo_*.jpg"):
    old.unlink()
n = 0
for item in status["items"]:
    for product in item["products"]:
        data = None
        if not a.placeholders and product.get("image_url", "").startswith("https://"):
            try:
                r = httpx.get(product["image_url"], timeout=30, follow_redirects=True)
                data = jpeg(Image.open(io.BytesIO(r.content))) if r.status_code == 200 else None
            except Exception as e:
                print("image download failed, using a placeholder:", e)
        name = f"vibe_demo_{n}.jpg"
        (DEMO / name).write_bytes(data or placeholder(n, product["title"]))
        product["image_url"] = f"bundle:{name}"
        n += 1

(DEMO / "vibe_demo.json").write_text(json.dumps({"prompt": a.prompt, "style": style, "status": status}, indent=1))
print(f"wrote vibe_demo.json and {n} images to {DEMO}")
