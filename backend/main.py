"""RoomVibe backend: thin, stateless proxy for AI calls. Keeps API keys out of the app.

MOCK=1 (default) returns canned responses so the app works offline / without keys.
Providers (checked against docs 2026-10-17):
  /render          Gemini image editing via the Interactions API (IMAGE_API_KEY, IMAGE_MODEL)
  /vibe/analyze    Claude vision + structured output (LLM_API_KEY)
  /vibe/products   SerpAPI Google Shopping (SHOPPING_API_KEY)
"""
import asyncio
import base64
import io
import logging
import os
import secrets

import anthropic
import httpx
from google import genai
from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, UploadFile
from PIL import Image
from pydantic import BaseModel, ValidationError

MOCK = os.getenv("MOCK", "1") == "1"
APP_SHARED_SECRET = os.getenv("APP_SHARED_SECRET", "")
IMAGE_API_KEY = os.getenv("IMAGE_API_KEY", "")
IMAGE_MODEL = os.getenv("IMAGE_MODEL", "gemini-nano-banana-2.1")
IMAGE_SIZE = os.getenv("IMAGE_SIZE", "1K")  # 512 / 1K / 2K
LLM_API_KEY = os.getenv("LLM_API_KEY", "")
LLM_MODEL = os.getenv("LLM_MODEL", "claude-opus-5-5")
SHOPPING_API_KEY = os.getenv("SHOPPING_API_KEY", "")
MAX_UPLOAD = 4 * 1024 * 1024  # Vercel caps bodies at 4.5 MB
TIMEOUT = 90
MAX_RESPONSE_B64 = 4_400_000  # base64 render must fit Vercel's 4.5 MB response cap

logging.getLogger("httpx").setLevel(logging.WARNING)  # INFO logs full URLs, incl. SerpAPI's api_key param

RENDER_PROMPT = (
    "This is a screenshot of a simple 3D dollhouse model of a real room: flat walls and colored blocks "
    "standing in for furniture. Turn it into a photorealistic interior photograph. Keep the exact camera "
    "angle, room shape, wall and window positions, and the position, size and orientation of every piece "
    "of furniture. Replace each block with a realistic piece of furniture of that type and size. "
    "Natural daylight, realistic materials and shadows. No people, no text, no labels."
)


def check_secret(x_app_secret: str = Header("")):
    if not MOCK and not APP_SHARED_SECRET:
        raise HTTPException(500, "APP_SHARED_SECRET must be set when MOCK=0")  # never run real providers unguarded
    if APP_SHARED_SECRET and not secrets.compare_digest(x_app_secret.encode(), APP_SHARED_SECRET.encode()):
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


def http() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=TIMEOUT)  # swapped for a mock transport in tests


def gemini() -> genai.Client:
    return genai.Client(api_key=IMAGE_API_KEY)  # swapped for a fake in tests


async def read_image(f: UploadFile) -> bytes:
    data = await f.read(MAX_UPLOAD + 1)
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "image too large; send JPEG <= 1536px")
    return data


def require(key: str, name: str):
    if not key:
        raise HTTPException(501, f"{name} not set; set it or use MOCK=1")


def output_aspect(data: bytes) -> str:
    """Closest output aspect to the snapshot's, so the layout is not squashed. The app crops to the same rule."""
    try:
        w, h = Image.open(io.BytesIO(data)).size
    except Exception:
        raise HTTPException(400, "image is not a readable JPEG/PNG")
    if h > w * 1.2:
        return "2:3"
    if w > h * 1.2:
        return "3:2"
    return "1:1"


@app.get("/health")
def health():
    return {"ok": True, "mock": MOCK}


@app.post("/render")
async def render(image: UploadFile = File(...), prompt: str = Form(""), style_ref: UploadFile | None = File(None)):
    data = await read_image(image)
    if MOCK:
        return {"image_base64": base64.b64encode(data).decode()}  # echo input as the "render"
    require(IMAGE_API_KEY, "IMAGE_API_KEY")
    full_prompt = RENDER_PROMPT + (f" Style: {prompt}" if prompt else "")
    images = [{"type": "image", "mime_type": image.content_type or "image/jpeg", "data": base64.b64encode(data).decode()}]
    if style_ref:
        ref = await read_image(style_ref)
        if len(data) + len(ref) > MAX_UPLOAD:
            raise HTTPException(413, "images too large together; send JPEGs <= 1536px")
        images.append({"type": "image", "mime_type": style_ref.content_type or "image/jpeg",
                       "data": base64.b64encode(ref).decode()})
        full_prompt += " Use the second image only as a style reference for materials, colors and decor."
    try:
        interaction = await gemini().aio.interactions.create(
            model=IMAGE_MODEL,
            input=[{"type": "text", "text": full_prompt}, *images],
            response_format={"type": "image", "mime_type": "image/jpeg",
                             "aspect_ratio": output_aspect(data), "image_size": IMAGE_SIZE},
            timeout=TIMEOUT,
        )
    except HTTPException:
        raise
    except Exception as e:  # SDK error classes live in a private module; match on name/status instead
        if "Timeout" in type(e).__name__:
            raise HTTPException(504, "image provider timed out")
        raise HTTPException(502, f"image provider error {getattr(e, 'status_code', '')}: {str(e)[:300]}")
    out = interaction.output_image
    b64 = out.data if out else None
    if not b64:
        raise HTTPException(502, "image provider returned no image")
    if len(b64) > MAX_RESPONSE_B64:
        raise HTTPException(502, "render too large to return")
    return {"image_base64": b64}


MOCK_STYLE = Style(
    style_name="Warm Japandi",
    palette=["#E8E1D5", "#B59F84", "#5B5348", "#2F2C28"],
    materials=["light oak", "linen", "rattan"],
    furniture_types=["low sofa", "round coffee table", "lounge chair"],
    decor_items=["paper floor lamp", "ceramic vase", "jute rug"],
    search_queries=["oak round coffee table", "linen low sofa", "paper floor lamp"],
)

ANALYZE_PROMPT = (
    "This is an interior design inspiration photo. Describe its style so we can restyle another room "
    "and shop for matching pieces. style_name: 2-3 words. palette: 4-6 hex colors from the photo. "
    "materials, furniture_types, decor_items: 3-5 short items each. search_queries: 4-6 specific shopping "
    "searches for pieces that would recreate this look (e.g. 'oak round coffee table')."
)


@app.post("/vibe/analyze", response_model=Style)
async def vibe_analyze(image: UploadFile = File(...)):
    data = await read_image(image)
    if MOCK:
        return MOCK_STYLE
    require(LLM_API_KEY, "LLM_API_KEY")
    client = anthropic.AsyncAnthropic(api_key=LLM_API_KEY, timeout=TIMEOUT)
    media_type = image.content_type if image.content_type in ("image/png", "image/webp", "image/gif") else "image/jpeg"
    try:
        msg = await client.beta.messages.parse(
            model=LLM_MODEL,
            max_tokens=4096,
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            output_config={"effort": "low"},
            output_format=Style,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": media_type,
                                             "data": base64.standard_b64encode(data).decode()}},
                {"type": "text", "text": ANALYZE_PROMPT},
            ]}],
        )
    except anthropic.APITimeoutError:
        raise HTTPException(504, "style model timed out")
    except anthropic.APIStatusError as e:
        raise HTTPException(502, f"style model error {e.status_code}: {e.message[:300]}")
    except anthropic.APIConnectionError:
        raise HTTPException(502, "style model unreachable")
    except (anthropic.APIResponseValidationError, ValidationError):
        raise HTTPException(502, "style model returned an invalid style")
    if msg.stop_reason == "refusal" or msg.parsed_output is None:
        raise HTTPException(502, "style model returned no style")
    return msg.parsed_output


async def shop(client: httpx.AsyncClient, query: str) -> list[Product]:
    r = await client.get("https://serpapi.com/search", params={
        "engine": "google_shopping", "q": query, "gl": "us", "hl": "en", "api_key": SHOPPING_API_KEY})
    if r.status_code != 200:
        raise httpx.HTTPStatusError(f"shopping provider error {r.status_code}", request=r.request, response=r)
    return [
        Product(title=it["title"], price=str(it.get("price", "")), image_url=it.get("thumbnail", ""),
                product_url=it["product_link"], retailer=it.get("source", ""))
        for it in r.json().get("shopping_results", [])[:3]
        if it.get("title") and it.get("product_link")
    ]


@app.post("/vibe/products")
async def vibe_products(style: Style):
    if MOCK:
        return {"products": [
            Product(title=q.title(), price="$199", image_url="https://picsum.photos/400",
                    product_url=f"https://example.com/{i}", retailer="Example").model_dump()
            for i, q in enumerate(style.search_queries[:8])
        ]}
    require(SHOPPING_API_KEY, "SHOPPING_API_KEY")
    async with http() as client:
        outcomes = await asyncio.gather(*(shop(client, q) for q in style.search_queries[:6]), return_exceptions=True)
    # One failed query only loses its own hits; all failing means the provider is down or the key is bad.
    results = [o for o in outcomes if not isinstance(o, BaseException)]
    if not results and outcomes:
        raise HTTPException(502, f"shopping provider failed: {outcomes[0]}"[:300])
    # Interleave so each query gets a slot before any gets a second one.
    products, seen = [], set()
    for rank in range(3):
        for hits in results:
            if rank < len(hits) and (key := hits[rank].product_url) not in seen:
                seen.add(key)
                products.append(hits[rank].model_dump())
    return {"products": products[:8]}
