"""RoomVibe backend: thin, stateless proxy for AI calls. Keeps API keys out of the app.

MOCK=1 (default) returns canned responses so the app works offline / without keys.
"""
import base64
import os
import secrets

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from pydantic import BaseModel

MOCK = os.getenv("MOCK", "1") == "1"
APP_SHARED_SECRET = os.getenv("APP_SHARED_SECRET", "")
MAX_UPLOAD = 4 * 1024 * 1024  # Vercel caps bodies at 4.5 MB


def check_secret(x_app_secret: str = Header("")):
    if APP_SHARED_SECRET and not secrets.compare_digest(x_app_secret, APP_SHARED_SECRET):
        raise HTTPException(401, "bad app secret")


app = FastAPI(dependencies=[Depends(check_secret)])


class Style(BaseModel):
    style_name: str
    palette: list[str]
    materials: list[str]
    furniture_types: list[str]
    decor_items: list[str]
    search_queries: list[str]


class Product(BaseModel):
    title: str
    price: str
    image_url: str
    product_url: str
    retailer: str


async def read_image(f: UploadFile) -> bytes:
    data = await f.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "image too large; send JPEG <= 1536px")
    return data


def not_configured():
    # Provider goes here once picked. Verify current model names/endpoints at build time.
    raise HTTPException(501, "AI provider not configured; set MOCK=1")


@app.get("/health")
def health():
    return {"ok": True, "mock": MOCK}


@app.post("/render")
async def render(image: UploadFile = File(...), prompt: str = Form(...), style_ref: UploadFile | None = File(None)):
    data = await read_image(image)
    if MOCK:
        return {"image_base64": base64.b64encode(data).decode()}  # echo input as the "render"
    not_configured()


@app.post("/vibe/analyze", response_model=Style)
async def vibe_analyze(image: UploadFile = File(...)):
    await read_image(image)
    if MOCK:
        return Style(
            style_name="Warm Japandi",
            palette=["#E8E1D5", "#B59F84", "#5B5348", "#2F2C28"],
            materials=["light oak", "linen", "rattan"],
            furniture_types=["low sofa", "round coffee table", "lounge chair"],
            decor_items=["paper floor lamp", "ceramic vase", "jute rug"],
            search_queries=["oak round coffee table", "linen low sofa", "paper floor lamp"],
        )
    not_configured()


@app.post("/vibe/products")
async def vibe_products(style: Style):
    if MOCK:
        return {"products": [
            Product(title=q.title(), price="$199", image_url="https://picsum.photos/400",
                    product_url="https://example.com", retailer="Example").model_dump()
            for q in style.search_queries[:8]
        ]}
    not_configured()
