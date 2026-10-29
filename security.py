"""
Server-side protection for the omw! API (server.py adds it):

  - HTTPS only: plain http:// requests are sent to https://, and browsers are told to always use https (HSTS)
  - security headers on every page (no sniffing, no framing by other sites, camera/location only for omw! itself)
  - sign-in required for everything that costs money or touches people's plans: the app sends its Firebase sign-in
    token (Authorization: Bearer ...), checked here with Firebase
  - rate limits per person (or per address when signed out), tighter for the AI features
  - a size limit on request bodies

Firebase isn't set up (no FIREBASE_SERVICE_ACCOUNT_JSON, e.g. on a laptop)? Then sign-in isn't checked, so local
development keeps working; the server says so once at startup.
"""
import os
import threading
import time
from collections import defaultdict, deque

from fastapi.responses import JSONResponse, RedirectResponse
from starlette.concurrency import run_in_threadpool

# which paths need you to be signed in, and how many calls each may make: (per minute, per hour)
SIGNED_IN = ("/ai/", "/plan", "/directions", "/find-times", "/parse-schedule", "/places", "/place-name", "/predict-departure")
LIMITS = {"ai": (8, 60), "api": (120, 2000), "open": (300, 5000), "account": (3, 10)}  # "open": per address, and a
# whole school or venue can share one address, so it's roomy
MAX_BODY = 3 * 1024 * 1024  # a selfie for the AI avatar is the biggest thing anyone sends
LOCAL = ("localhost", "127.0.0.1", "0.0.0.0", "testserver")

_hits = defaultdict(deque)   # (bucket, who) -> times of recent calls
_lock = threading.Lock()
_tokens = {}                 # sign-in token -> (uid, checked at): skip re-checking the same token for a few minutes
_auth = None                 # firebase_admin.auth once Firebase is set up; False when it isn't


def _firebase_auth():
    global _auth
    if _auth is None:
        try:
            from calendar_feed import firestore_client
            firestore_client()  # sets up firebase_admin with the service account
            from firebase_admin import auth
            _auth = auth
        except Exception as e:
            print(f"[security] sign-in isn't checked on this server ({e})")
            _auth = False
    return _auth


def _uid(token):
    """The person a Firebase sign-in token belongs to, or None if it isn't valid."""
    now = time.time()
    hit = _tokens.get(token)
    if hit and now - hit[1] < 300:
        return hit[0]
    try:
        uid = _auth.verify_id_token(token)["uid"]
    except Exception:
        return None
    if len(_tokens) > 5000:
        _tokens.clear()
    _tokens[token] = (uid, now)
    return uid


def _allowed(bucket, who):
    per_min, per_hour = LIMITS[bucket]
    now = time.time()
    with _lock:
        q = _hits[(bucket, who)]
        while q and now - q[0] > 3600:
            q.popleft()
        if len(q) >= per_hour or sum(1 for t in q if now - t < 60) >= per_min:
            return False
        q.append(now)
        if len(_hits) > 50000:  # forget quiet visitors
            for k in [k for k, v in _hits.items() if not v or now - v[-1] > 3600]:
                del _hits[k]
        return True


def _headers(response, https):
    h = response.headers
    h.setdefault("X-Content-Type-Options", "nosniff")
    h.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    h.setdefault("X-Frame-Options", "SAMEORIGIN")
    h.setdefault("Content-Security-Policy", "frame-ancestors 'self'; base-uri 'self'; object-src 'none'")
    h.setdefault("Permissions-Policy", "camera=(self), geolocation=(self), microphone=(), payment=()")
    if https:
        h.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    return response


def add_to(app):
    _firebase_auth()

    @app.middleware("http")
    async def protect(request, call_next):
        path, host = request.url.path, (request.url.hostname or "")
        proto = request.headers.get("x-forwarded-proto", request.url.scheme)
        # 1. https only (the hosting provider ends HTTPS and tells us how the request came in)
        if proto == "http" and host not in LOCAL and request.headers.get("x-forwarded-proto"):
            return RedirectResponse(str(request.url.replace(scheme="https")), status_code=308)
        https = proto == "https"
        if path.startswith("/__/") or request.method == "OPTIONS":  # Firebase's sign-in pages; CORS preflights
            return await call_next(request)

        # 2. size
        if int(request.headers.get("content-length") or 0) > MAX_BODY:
            return _headers(JSONResponse({"detail": "That's too big to send."}, status_code=413), https)

        # 3. who's asking
        who = request.client.host if request.client else "?"
        token = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
        needs_sign_in = path.startswith(SIGNED_IN)
        if token and _auth:
            uid = await run_in_threadpool(_uid, token)
            if uid:
                who = uid
            elif needs_sign_in:
                return _headers(JSONResponse({"detail": "Sign in again."}, status_code=401), https)
        elif needs_sign_in and _auth:
            return _headers(JSONResponse({"detail": "Sign in first."}, status_code=401), https)

        # 4. how often
        bucket = ("account" if path.startswith("/account/") else "ai" if path.startswith("/ai/") and request.method == "POST"
                  else "api" if needs_sign_in else "open")
        if not path.startswith("/static/") and path != "/health" and not _allowed(bucket, who):
            return _headers(JSONResponse({"detail": "Too many tries. Wait a minute, then try again."}, status_code=429,
                                         headers={"Retry-After": "60"}), https)

        return _headers(await call_next(request), https)
