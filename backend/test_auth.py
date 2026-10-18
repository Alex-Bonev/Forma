import base64
import json
import time

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

import main
from main import app

c = TestClient(app)
URL = "https://proj.supabase.co"
KEY = ec.generate_private_key(ec.SECP256R1())
OTHER = ec.generate_private_key(ec.SECP256R1())


def jwk(private_key, kid="k1"):
    d = json.loads(jwt.algorithms.ECAlgorithm.to_jwk(private_key.public_key()))
    return {**d, "kid": kid, "alg": "ES256", "use": "sig"}


def claims(**over):
    c = {"iss": f"{URL}/auth/v1", "aud": "authenticated", "role": "authenticated", "sub": "u1",
         "exp": int(time.time()) + 3600, **over}
    return {k: v for k, v in c.items() if v is not None}


def token(key=KEY, kid="k1", **over):
    return jwt.encode(claims(**over), key, algorithm="ES256", headers={"kid": kid} if kid else None)


def unsigned():
    b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    return f"{b64({'alg': 'none', 'typ': 'JWT', 'kid': 'k1'})}.{b64(claims())}."


def bearer(t):
    return {"Authorization": f"Bearer {t}"}


@pytest.fixture
def supabase(monkeypatch):
    """SUPABASE_URL set, real-provider mode, a fresh JWKS cache, and a fake JWKS endpoint that counts fetches."""
    fetches = []

    async def fetch():
        fetches.append(1)
        return {"keys": [jwk(KEY)]}

    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "SUPABASE_URL", URL)
    monkeypatch.setattr(main, "APP_SHARED_SECRET", "s")
    monkeypatch.setattr(main, "_jwks", {"keys": {}, "fetched": -float("inf"), "attempted": -float("inf")})
    monkeypatch.setattr(main, "_calls", {})
    monkeypatch.setattr(main, "fetch_jwks", fetch)
    return fetches


def test_valid_token(supabase):
    assert c.get("/health", headers=bearer(token())).status_code == 200
    assert c.get("/health", headers={"Authorization": f"bearer {token()}"}).status_code == 200
    assert len(supabase) == 1  # cached after the first fetch


def test_rejected_tokens(supabase):
    bad = [
        token(exp=int(time.time()) - 3600),          # expired
        token(aud="anon"),                            # wrong audience
        token(iss="https://evil.supabase.co/auth/v1"),  # wrong issuer
        token(role="anon"),                           # validly signed, but not a signed-in user
        token(key=OTHER),                             # bad signature
        jwt.encode({"sub": "u1"}, "x" * 32, algorithm="HS256", headers={"kid": "k1"}),  # symmetric
        unsigned(),                                   # alg none
        token(kid=None),                              # no kid
        token(sub=None),                              # no user
        "not-a-jwt",
    ]
    for t in bad:
        assert c.get("/health", headers=bearer(t)).status_code == 401
    assert c.get("/health").status_code == 401


def test_unknown_kid_refetch_is_bounded(supabase):
    assert c.get("/health", headers=bearer(token())).status_code == 200
    for _ in range(3):
        assert c.get("/health", headers=bearer(token(kid="nope"))).status_code == 401
    assert len(supabase) == 1  # the first fetch was just now: no refetch storm
    main._jwks["attempted"] -= main.JWKS_MIN_REFETCH
    assert c.get("/health", headers=bearer(token(kid="nope"))).status_code == 401
    assert len(supabase) == 2  # an unknown kid refetches once the window has passed


def test_rotated_key_is_picked_up(supabase, monkeypatch):
    assert c.get("/health", headers=bearer(token())).status_code == 200

    async def rotated():
        return {"keys": [jwk(KEY), jwk(OTHER, kid="k2")]}

    monkeypatch.setattr(main, "fetch_jwks", rotated)
    main._jwks["attempted"] -= main.JWKS_MIN_REFETCH
    assert c.get("/health", headers=bearer(token(key=OTHER, kid="k2"))).status_code == 200


def test_jwks_outage(supabase, monkeypatch):
    async def down():
        raise httpx.ConnectTimeout("timeout")

    monkeypatch.setattr(main, "fetch_jwks", down)
    assert c.get("/health", headers=bearer(token())).status_code == 503
    assert c.get("/health", headers={"X-App-Secret": "s"}).status_code == 200  # the secret does not need Supabase


def test_secret_still_accepted(supabase):
    assert c.get("/health", headers={"X-App-Secret": "s"}).status_code == 200
    assert c.get("/health", headers={"X-App-Secret": "wrong"}).status_code == 401
    assert c.get("/health", headers={"X-App-Secret": "s", **bearer("garbage")}).status_code == 200
    assert supabase == []  # a good secret never touches the JWKS


def test_bearer_only_backend(supabase, monkeypatch):
    monkeypatch.setattr(main, "APP_SHARED_SECRET", "")
    assert c.get("/health", headers=bearer(token())).status_code == 200
    assert c.get("/health", headers={"X-App-Secret": ""}).status_code == 401


def test_no_supabase_url_unchanged(monkeypatch):
    monkeypatch.setattr(main, "SUPABASE_URL", "")
    monkeypatch.setattr(main, "APP_SHARED_SECRET", "s")
    monkeypatch.setattr(main, "fetch_jwks", lambda: pytest.fail("no JWKS fetch without SUPABASE_URL"))
    assert c.get("/health", headers=bearer(token())).status_code == 401
    assert c.get("/health", headers={"X-App-Secret": "s"}).status_code == 200
    monkeypatch.setattr(main, "MOCK", False)
    monkeypatch.setattr(main, "APP_SHARED_SECRET", "")
    assert c.get("/health").status_code == 500  # MOCK=0 with no guard configured refuses to run


def test_mock_stays_open(monkeypatch):
    monkeypatch.setattr(main, "MOCK", True)
    monkeypatch.setattr(main, "APP_SHARED_SECRET", "")
    monkeypatch.setattr(main, "SUPABASE_URL", URL)
    assert c.get("/health").status_code == 200


def test_hmac_key_in_jwks_is_ignored(supabase, monkeypatch):
    secret = b"x" * 32

    async def with_oct():
        oct_key = {"kty": "oct", "kid": "h1", "alg": "HS256", "k": base64.urlsafe_b64encode(secret).decode().rstrip("=")}
        return {"keys": [oct_key, jwk(KEY)]}

    monkeypatch.setattr(main, "fetch_jwks", with_oct)
    forged = jwt.encode(claims(), secret, algorithm="HS256", headers={"kid": "h1"})
    assert c.get("/health", headers=bearer(token())).status_code == 200
    assert set(main._jwks["keys"]) == {"k1"}  # the oct key was skipped
    assert c.get("/health", headers=bearer(forged)).status_code == 401


def test_supabase_url_must_be_https():
    assert main.check_supabase_url("https://proj.supabase.co") == "https://proj.supabase.co"
    assert main.check_supabase_url("http://127.0.0.1:54321") and main.check_supabase_url("http://localhost:54321")
    assert main.check_supabase_url("") == ""
    for bad in ["http://proj.supabase.co", "http://192.168.1.5:54321", "ftp://proj.supabase.co", "proj.supabase.co"]:
        with pytest.raises(RuntimeError, match="SUPABASE_URL"):
            main.check_supabase_url(bad)


def test_stale_keys_expire(supabase, monkeypatch):
    assert c.get("/health", headers=bearer(token())).status_code == 200

    async def down():
        raise httpx.ConnectError("down")

    monkeypatch.setattr(main, "fetch_jwks", down)
    main._jwks["fetched"] -= main.JWKS_TTL  # stale: a refresh is tried and fails, the cached key still works
    main._jwks["attempted"] -= main.JWKS_MIN_REFETCH
    assert c.get("/health", headers=bearer(token())).status_code == 200
    main._jwks["fetched"] -= main.JWKS_MAX_AGE  # past the hard limit: dropped
    main._jwks["attempted"] -= main.JWKS_MIN_REFETCH
    assert c.get("/health", headers=bearer(token())).status_code == 503
    assert main._jwks["keys"] == {}
    assert c.get("/health", headers={"X-App-Secret": "s"}).status_code == 200


def test_empty_jwks_keeps_cache(supabase, monkeypatch):
    assert c.get("/health", headers=bearer(token())).status_code == 200

    async def empty():
        return {"keys": [{"kty": "oct", "kid": "h1", "k": "eA"}]}  # nothing usable

    monkeypatch.setattr(main, "fetch_jwks", empty)
    main._jwks["fetched"] -= main.JWKS_TTL
    main._jwks["attempted"] -= main.JWKS_MIN_REFETCH
    assert c.get("/health", headers=bearer(token())).status_code == 200
    assert set(main._jwks["keys"]) == {"k1"}


def test_rate_limit(supabase, monkeypatch):
    monkeypatch.setattr(main, "RATE_LIMIT_PER_MIN", 3)
    for _ in range(3):
        assert c.get("/health", headers=bearer(token())).status_code == 200
    r = c.get("/health", headers=bearer(token()))
    assert r.status_code == 429 and "too many" in r.json()["detail"]
    assert c.get("/health", headers=bearer(token(sub="u2"))).status_code == 200  # users are counted separately
    for _ in range(5):
        assert c.get("/health", headers={"X-App-Secret": "s"}).status_code == 200  # the secret is not limited
    main._calls["u1"] = (main._calls["u1"][0] - 1, 3)  # the next minute starts fresh
    assert c.get("/health", headers=bearer(token())).status_code == 200


def test_rate_limit_off_in_mock(supabase, monkeypatch):
    monkeypatch.setattr(main, "MOCK", True)
    monkeypatch.setattr(main, "RATE_LIMIT_PER_MIN", 1)
    for _ in range(3):
        assert c.get("/health", headers=bearer(token())).status_code == 200
