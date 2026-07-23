"""
Mock BFF + hosted checkout server for prototyping Apple's ExternalPurchaseCustomLink
(EU external purchase link) flow without the real Apple entitlement.

Plays two roles on one FastAPI app:
  1. BFF API  - /tokens, /tokens/acknowledged, /checkout/session,
                /checkout/session/{id}/verify, /debug/*
  2. Checkout - /checkout/start (handoff redemption), /checkout/{id},
                /checkout/{id}/payment, /checkout/{id}/confirm,
                /checkout/{id}/action/{action}

In-memory only. Restarting the server clears all state (or use /debug/reset).
"""

import asyncio
import base64
import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Literal, Optional

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel

app = FastAPI(title="External Purchase Link Mock Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

SESSION_TTL_MINUTES = 15
HANDOFF_TTL_SECONDS = 60
SESSION_COOKIE_NAME = "eplp_session"
APP_URL_SCHEME = "immowelt"  # matches the app's registered custom URL scheme

CATALOG = {
    "com.example.premium.monthly": {
        "name": "Premium Placement",
        "price": "€29.99",
        "period": "per month",
    },
    "com.example.premium.yearly": {
        "name": "Premium Placement",
        "price": "€299.99",
        "period": "per year",
    },
    "com.example.boost": {
        "name": "Listing Boost",
        "price": "€9.99",
        "period": "one-time",
    },
}
DEFAULT_PRODUCT = {"name": "Premium Subscription", "price": "€19.99", "period": "per month"}


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() if dt else None


def epoch_ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


# ---------------------------------------------------------------------------
# In-memory storage
# ---------------------------------------------------------------------------

SessionStatus = Literal["pending", "paid", "cancelled", "expired"]

sessions: Dict[str, dict] = {}
token_submissions: List[dict] = []
# device_id -> {idempotency_key -> acknowledgement record}
token_acknowledgements: Dict[str, Dict[str, dict]] = {}
# handoff token -> {session_id, user_id, expires_at, redeemed}
handoffs: Dict[str, dict] = {}
handoff_lock = asyncio.Lock()
handoff_debug_mode: str = "normal"
# web session cookie value -> {session_id, user_id}
web_sessions: Dict[str, dict] = {}


def effective_status(session: dict) -> SessionStatus:
    """Pending sessions past their TTL read as expired. Terminal states
    (paid/cancelled) stick, even past expiry, since they already happened."""
    if session["status"] == "pending" and now_utc() > session["expires_at"]:
        return "expired"
    return session["status"]


def get_session_or_404(session_id: str) -> dict:
    session = sessions.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail="session not found")
    return session


def product_info(product_id: str) -> dict:
    return CATALOG.get(product_id, DEFAULT_PRODUCT)


# ---------------------------------------------------------------------------
# Request logging middleware
# ---------------------------------------------------------------------------


@app.middleware("http")
async def log_requests(request: Request, call_next):
    body = await request.body()

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    request._receive = receive  # allow downstream handlers to re-read the body

    body_text = body.decode("utf-8", errors="replace") if body else ""
    print(f"[{now_utc().isoformat()}] {request.method} {request.url.path} body={body_text}", flush=True)

    response = await call_next(request)
    return response


# ---------------------------------------------------------------------------
# BFF API models
# ---------------------------------------------------------------------------


AcquisitionAbsenceReason = Literal["period_elapsed_or_not_issued"]


class TokenReportRequest(BaseModel):
    """The client extracts `externalPurchaseId` out of Apple's base64 token
    and reports only that UUID — the raw base64 token stays on-device for
    diagnostics and is never transmitted. `services_purchase_id` being null
    means the client's token subsystem failed and must never be reported as
    data (see `post_tokens`); `acquisition_purchase_id` being null is a
    legitimate, successful report for a returning customer."""

    acquisition_purchase_id: Optional[str] = None
    services_purchase_id: Optional[str] = None
    acquisition_absence_reason: Optional[AcquisitionAbsenceReason] = None
    fetched_at: datetime


class CheckoutSessionRequest(BaseModel):
    product_id: str
    user_id: str
    acquisition_token: Optional[str] = None
    services_token: Optional[str] = None


class ForceStatusRequest(BaseModel):
    status: SessionStatus


HandoffMode = Literal["normal", "already_redeemed", "expired", "wrong_session", "reject"]


class HandoffModeRequest(BaseModel):
    mode: HandoffMode


# ---------------------------------------------------------------------------
# BFF API endpoints
# ---------------------------------------------------------------------------


def validate_uuid(value: Optional[str], field: str) -> None:
    if value is None:
        return
    try:
        uuid.UUID(value)
    except ValueError:
        raise HTTPException(status_code=400, detail=f"{field} is not a valid UUID")


def derive_idempotency_key(acquisition_purchase_id: Optional[str], services_purchase_id: str) -> str:
    """Purchase IDs are already stable UUIDs, so they double as the
    idempotency key themselves — no client-supplied idempotency header
    needed. Resubmitting the same pair of IDs is naturally a no-op."""
    return f"acq:{acquisition_purchase_id or 'none'}|svc:{services_purchase_id}"


@app.post("/tokens")
async def post_tokens(payload: TokenReportRequest, device_id: str = Header(..., alias="Device-Id")):
    if payload.services_purchase_id is None:
        # A missing services purchase ID means the client's own token
        # subsystem broke — the client is expected to filter this case out
        # itself. Reporting it as data would corrupt acquisition/services
        # analytics, so this is a hard reject rather than a tolerated null
        # (unlike acquisition_purchase_id, see the docstring above).
        raise HTTPException(
            status_code=400,
            detail=(
                "services_purchase_id is required; a null value indicates a "
                "client-side token subsystem failure and must not be reported as data"
            ),
        )
    validate_uuid(payload.acquisition_purchase_id, "acquisition_purchase_id")
    validate_uuid(payload.services_purchase_id, "services_purchase_id")

    idempotency_key = derive_idempotency_key(payload.acquisition_purchase_id, payload.services_purchase_id)

    device_acks = token_acknowledgements.setdefault(device_id, {})
    if idempotency_key in device_acks:
        return device_acks[idempotency_key]

    record = {
        "idempotency_key": idempotency_key,
        "acquisition_purchase_id": payload.acquisition_purchase_id,
        "services_purchase_id": payload.services_purchase_id,
        "acquisition_absence_reason": payload.acquisition_absence_reason,
        "fetched_at": iso(payload.fetched_at),
        "acknowledged_at": iso(now_utc()),
    }
    device_acks[idempotency_key] = record
    token_submissions.append({"device_id": device_id, **record})
    return record


@app.get("/tokens/acknowledged")
async def get_tokens_acknowledged(device_id: str):
    return {"idempotency_keys": list(token_acknowledgements.get(device_id, {}).keys())}


# ---------------------------------------------------------------------------
# Mock token minting
# ---------------------------------------------------------------------------

APP_APPLE_ID = 1234567890
BUNDLE_ID = "de.immowelt.app"
TOKEN_LIFETIME = timedelta(days=365)

MintTokenType = Literal["ACQUISITION", "SERVICES"]
MintTokenVariant = Literal[
    "valid",
    "expired",
    "expiring_soon",
    "base64url",
    "malformed_json",
    "invalid_base64",
    "type_mismatch",
    "missing_optional_fields",
    "unknown_extra_field",
]


def encode_token(payload: dict, urlsafe: bool) -> str:
    raw = json.dumps(payload).encode("utf-8")
    if urlsafe:
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return base64.b64encode(raw).decode("ascii")


@app.get("/debug/mint-token")
async def debug_mint_token(
    type: MintTokenType = Query(...),
    variant: MintTokenVariant = Query("valid"),
):
    if variant == "invalid_base64":
        # Not base64 at all — decoding must fail before JSON parsing is
        # even attempted.
        return {"value": "%%% not base64 %%%"}

    if variant == "malformed_json":
        # Valid base64, but the decoded bytes aren't valid JSON.
        return {"value": base64.b64encode(b"{not valid json").decode("ascii")}

    created = now_utc()
    payload = {
        "appAppleId": APP_APPLE_ID,
        "bundleId": BUNDLE_ID,
        # Apple documents these as epoch milliseconds, not seconds.
        "tokenCreationDate": epoch_ms(created),
        "externalPurchaseId": str(uuid.uuid4()),
        "tokenType": type,
        "tokenExpirationDate": epoch_ms(created + TOKEN_LIFETIME),
    }

    if variant == "expired":
        payload["tokenExpirationDate"] = epoch_ms(created - timedelta(days=1))
    elif variant == "expiring_soon":
        payload["tokenExpirationDate"] = epoch_ms(created + timedelta(minutes=5))
    elif variant == "type_mismatch":
        payload["tokenType"] = "SERVICES" if type == "ACQUISITION" else "ACQUISITION"
    elif variant == "missing_optional_fields":
        # Apple documents tokenType/tokenExpirationDate as custom-link-only;
        # their absence must be tolerated by the client's decoder.
        del payload["tokenType"]
        del payload["tokenExpirationDate"]
    elif variant == "unknown_extra_field":
        payload["futureAppleField"] = "the-client-does-not-know-this-field"

    return {"value": encode_token(payload, urlsafe=(variant == "base64url"))}


# ---------------------------------------------------------------------------
# Checkout session + auth handoff
# ---------------------------------------------------------------------------


@app.post("/checkout/session")
async def create_checkout_session(payload: CheckoutSessionRequest, request: Request):
    session_id = uuid.uuid4().hex
    created_at = now_utc()
    expires_at = created_at + timedelta(minutes=SESSION_TTL_MINUTES)

    sessions[session_id] = {
        "session_id": session_id,
        "product_id": payload.product_id,
        "user_id": payload.user_id,
        "acquisition_token": payload.acquisition_token,
        "services_token": payload.services_token,
        "status": "pending",
        "created_at": created_at,
        "expires_at": expires_at,
        "verified_at": None,
    }

    # A session is never created without a handoff — the checkout_url always
    # points at the redemption endpoint, never straight at the session.
    handoff_token = uuid.uuid4().hex
    handoff_expires_at = created_at + timedelta(seconds=HANDOFF_TTL_SECONDS)
    handoffs[handoff_token] = {
        "session_id": session_id,
        "user_id": payload.user_id,
        "expires_at": handoff_expires_at,
        "redeemed": False,
    }

    base = str(request.base_url).rstrip("/")
    return {
        "session_id": session_id,
        "checkout_url": f"{base}/checkout/start?handoff={handoff_token}",
        "handoff_expires_at": iso(handoff_expires_at),
        "expires_at": iso(expires_at),
    }


@app.get("/checkout/session/{session_id}/verify")
async def verify_session(session_id: str):
    session = get_session_or_404(session_id)
    return {
        "status": effective_status(session),
        "product_id": session["product_id"],
        "verified_at": iso(session["verified_at"]),
    }


def render_handoff_error_page(message: str) -> HTMLResponse:
    body = f"""
      <p>{message}</p>
      <div class="note">
        This link can only be used once and expires quickly for your security.
        Please return to the app and start checkout again.
      </div>
    """
    return HTMLResponse(render_page("Checkout", "Unable to continue", body), status_code=401)


@app.get("/checkout/start")
async def checkout_start(handoff: str):
    # The debug override short-circuits before touching real handoff state,
    # so a specific failure mode can be exercised deterministically without
    # needing to actually expire/replay a token.
    if handoff_debug_mode == "already_redeemed":
        return render_handoff_error_page("This checkout link has already been used.")
    if handoff_debug_mode == "expired":
        return render_handoff_error_page("This checkout link has expired.")
    if handoff_debug_mode == "wrong_session":
        return render_handoff_error_page("This checkout link is not valid for this session.")
    if handoff_debug_mode == "reject":
        return render_handoff_error_page("This checkout link is invalid.")

    # Redeem-then-mutate happens inside a lock with no `await` between the
    # check and the write, so a replayed request racing the original always
    # loses — exactly one caller ever observes `redeemed=False`.
    async with handoff_lock:
        record = handoffs.get(handoff)
        if record is None:
            return render_handoff_error_page("This checkout link is invalid.")
        if record["redeemed"]:
            return render_handoff_error_page("This checkout link has already been used.")
        if now_utc() > record["expires_at"]:
            return render_handoff_error_page("This checkout link has expired.")
        record["redeemed"] = True
        session_id = record["session_id"]
        user_id = record["user_id"]

    cookie_value = uuid.uuid4().hex
    web_sessions[cookie_value] = {"session_id": session_id, "user_id": user_id}

    response = RedirectResponse(url=f"/checkout/{session_id}", status_code=302)
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=cookie_value,
        httponly=True,
        samesite="lax",
        path="/",
    )
    return response


def get_web_session(request: Request) -> Optional[dict]:
    cookie_value = request.cookies.get(SESSION_COOKIE_NAME)
    if not cookie_value:
        return None
    return web_sessions.get(cookie_value)


def require_web_session(session_id: str, request: Request) -> Optional[HTMLResponse]:
    """Returns an error response if unauthenticated, else None. The cookie
    is bound to the specific session_id it was issued for — a handoff (and
    the cookie it produces) for session A must not open session B."""
    web_session = get_web_session(request)
    if web_session is None or web_session["session_id"] != session_id:
        body = """
          <p>You need to open this checkout from the app.</p>
          <div class="note">Missing or invalid session — please return to the app and try again.</div>
        """
        return HTMLResponse(render_page("Checkout", "Sign-in required", body), status_code=401)
    return None


@app.post("/debug/handoff-mode")
async def debug_handoff_mode(payload: HandoffModeRequest):
    global handoff_debug_mode
    handoff_debug_mode = payload.mode
    return {"mode": handoff_debug_mode}


# ---------------------------------------------------------------------------
# Debug endpoints
# ---------------------------------------------------------------------------


@app.get("/debug/sessions")
async def debug_list_sessions():
    return {
        "sessions": [
            {
                "session_id": s["session_id"],
                "product_id": s["product_id"],
                "user_id": s["user_id"],
                "acquisition_token": s["acquisition_token"],
                "services_token": s["services_token"],
                "status": effective_status(s),
                "raw_status": s["status"],
                "created_at": iso(s["created_at"]),
                "expires_at": iso(s["expires_at"]),
                "verified_at": iso(s["verified_at"]),
            }
            for s in sessions.values()
        ]
    }


@app.post("/debug/sessions/{session_id}/force")
async def debug_force_session(session_id: str, payload: ForceStatusRequest):
    session = get_session_or_404(session_id)
    session["status"] = payload.status
    if payload.status == "paid":
        session["verified_at"] = now_utc()
    return {
        "session_id": session_id,
        "status": effective_status(session),
        "verified_at": iso(session["verified_at"]),
    }


@app.post("/debug/reset")
async def debug_reset():
    global handoff_debug_mode
    sessions.clear()
    token_submissions.clear()
    token_acknowledgements.clear()
    handoffs.clear()
    web_sessions.clear()
    handoff_debug_mode = "normal"
    return {"reset": True}


# ---------------------------------------------------------------------------
# Checkout website
# ---------------------------------------------------------------------------


PAGE_SHELL = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0; padding: 0; min-height: 100vh;
    background: #f4f5f7;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    color: #1a1a1a;
    display: flex; align-items: center; justify-content: center;
  }}
  .card {{
    width: 100%; max-width: 420px; margin: 24px;
    background: #ffffff; border-radius: 16px;
    box-shadow: 0 2px 16px rgba(0,0,0,0.08);
    overflow: hidden;
  }}
  .header {{
    background: #12336b; color: #fff; padding: 20px 24px;
  }}
  .header .brand {{ font-size: 15px; font-weight: 600; letter-spacing: 0.02em; opacity: 0.85; }}
  .header h1 {{ font-size: 20px; margin: 6px 0 0; font-weight: 600; }}
  .body {{ padding: 24px; }}
  .row {{ display: flex; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid #eee; font-size: 15px; }}
  .row:last-of-type {{ border-bottom: none; }}
  .row .label {{ color: #666; }}
  .row .value {{ font-weight: 600; }}
  .total {{ font-size: 18px; margin-top: 12px; }}
  .field {{ margin-bottom: 16px; }}
  .field label {{ display: block; font-size: 13px; color: #555; margin-bottom: 6px; }}
  .field input {{
    width: 100%; padding: 12px; border: 1px solid #ccc; border-radius: 8px;
    font-size: 15px;
  }}
  .field.two {{ display: flex; gap: 12px; }}
  button, .btn {{
    display: block; width: 100%; padding: 14px; margin-top: 12px;
    border: none; border-radius: 10px; font-size: 16px; font-weight: 600;
    cursor: pointer; text-align: center; text-decoration: none;
  }}
  .btn-primary {{ background: #12336b; color: #fff; }}
  .btn-secondary {{ background: #eef0f4; color: #12336b; }}
  .btn-danger {{ background: #fff; color: #b3261e; border: 1px solid #b3261e; }}
  .btn-ghost {{ background: #fff; color: #666; border: 1px solid #ddd; font-size: 13px; padding: 10px; }}
  .note {{ font-size: 12px; color: #888; margin-top: 20px; line-height: 1.5; }}
  form {{ margin: 0; }}
</style>
</head>
<body>
  <div class="card">
    <div class="header">
      <div class="brand">PropertyHub</div>
      <h1>{heading}</h1>
    </div>
    <div class="body">
      {body}
    </div>
  </div>
</body>
</html>
"""


def render_page(title: str, heading: str, body: str) -> str:
    return PAGE_SHELL.format(title=title, heading=heading, body=body)


@app.get("/checkout/{session_id}", response_class=HTMLResponse)
async def checkout_step1(session_id: str, request: Request):
    auth_error = require_web_session(session_id, request)
    if auth_error is not None:
        return auth_error

    session = get_session_or_404(session_id)
    status = effective_status(session)
    product = product_info(session["product_id"])

    if status != "pending":
        return HTMLResponse(render_status_page(session_id, status))

    body = f"""
      <div class="row"><span class="label">Product</span><span class="value">{product['name']}</span></div>
      <div class="row"><span class="label">Billing</span><span class="value">{product['period']}</span></div>
      <div class="row total"><span class="label">Total</span><span class="value">{product['price']}</span></div>

      <a class="btn btn-primary" href="/checkout/{session_id}/payment">Proceed to Payment</a>
      <a class="btn btn-ghost" href="https://example.com" target="_blank" rel="noopener">Open partner site (external — should leave the app)</a>
      <div class="note">Session {session_id} &middot; expires {iso(session['expires_at'])}</div>
    """
    return HTMLResponse(render_page("Checkout", "Confirm your order", body))


@app.get("/checkout/{session_id}/payment", response_class=HTMLResponse)
async def checkout_step2(session_id: str, request: Request):
    auth_error = require_web_session(session_id, request)
    if auth_error is not None:
        return auth_error

    session = get_session_or_404(session_id)
    status = effective_status(session)
    if status != "pending":
        return HTMLResponse(render_status_page(session_id, status))

    body = f"""
      <form method="post" action="/checkout/{session_id}/payment">
        <div class="field">
          <label>Card number</label>
          <input type="text" placeholder="4242 4242 4242 4242" value="4242 4242 4242 4242">
        </div>
        <div class="field two">
          <div style="flex:1">
            <label>Expiry</label>
            <input type="text" placeholder="MM/YY" value="12/29">
          </div>
          <div style="flex:1">
            <label>CVC</label>
            <input type="text" placeholder="123" value="123">
          </div>
        </div>
        <div class="field">
          <label>Name on card</label>
          <input type="text" placeholder="Jane Doe" value="Test User">
        </div>
        <button type="submit" class="btn-primary">Review Order</button>
      </form>
      <div class="note">This is a mock payment form. No card data is real or transmitted anywhere.</div>
    """
    return HTMLResponse(render_page("Payment details", "Enter payment details", body))


@app.post("/checkout/{session_id}/payment")
async def checkout_step2_submit(session_id: str, request: Request):
    auth_error = require_web_session(session_id, request)
    if auth_error is not None:
        return auth_error
    get_session_or_404(session_id)
    return RedirectResponse(url=f"/checkout/{session_id}/confirm", status_code=303)


@app.get("/checkout/{session_id}/confirm", response_class=HTMLResponse)
async def checkout_step3(session_id: str, request: Request):
    auth_error = require_web_session(session_id, request)
    if auth_error is not None:
        return auth_error

    session = get_session_or_404(session_id)
    status = effective_status(session)
    if status != "pending":
        return HTMLResponse(render_status_page(session_id, status))

    product = product_info(session["product_id"])

    def action_form(action: str, label: str, css_class: str) -> str:
        return f"""
          <form method="post" action="/checkout/{session_id}/action/{action}">
            <button type="submit" class="{css_class}">{label}</button>
          </form>
        """

    body = f"""
      <div class="row"><span class="label">Product</span><span class="value">{product['name']}</span></div>
      <div class="row total"><span class="label">Total</span><span class="value">{product['price']}</span></div>

      {action_form('complete', 'Complete Purchase', 'btn-primary')}
      {action_form('cancel', 'Cancel', 'btn-secondary')}

      <div class="note">Test scenarios:</div>
      {action_form('slow', 'Simulate slow processing', 'btn-ghost')}
      {action_form('fail', 'Simulate payment failure', 'btn-ghost')}
      {action_form('forge', 'Redirect with forged success', 'btn-ghost')}
    """
    return HTMLResponse(render_page("Confirm payment", "Review &amp; confirm", body))


def render_status_page(session_id: str, status: str) -> str:
    body = f"""
      <p>This checkout session is <strong>{status}</strong> and can no longer be acted on.</p>
      <div class="note">Session {session_id}</div>
    """
    return render_page("Checkout", "Session " + status, body)


def redirect_to_app(session_id: str, status: str) -> RedirectResponse:
    url = f"{APP_URL_SCHEME}://payment-complete?session_id={session_id}&status={status}"
    return RedirectResponse(url=url, status_code=303)


async def _mark_paid_after_delay(session_id: str, delay_seconds: float):
    await asyncio.sleep(delay_seconds)
    session = sessions.get(session_id)
    if session is not None:
        session["status"] = "paid"
        session["verified_at"] = now_utc()


@app.post("/checkout/{session_id}/action/{action}")
async def checkout_action(session_id: str, action: str, request: Request, background_tasks: BackgroundTasks):
    auth_error = require_web_session(session_id, request)
    if auth_error is not None:
        return auth_error

    session = get_session_or_404(session_id)

    if action == "complete":
        session["status"] = "paid"
        session["verified_at"] = now_utc()
        return redirect_to_app(session_id, "paid")

    if action == "cancel":
        session["status"] = "cancelled"
        return redirect_to_app(session_id, "cancelled")

    if action == "slow":
        # Redirects immediately; the backend only confirms 20s later.
        # Exercises the app's pendingVerification / poll-the-verify-endpoint path.
        background_tasks.add_task(_mark_paid_after_delay, session_id, 20.0)
        return redirect_to_app(session_id, "pending")

    if action == "fail":
        # Session is left untouched server-side (still pending/unpaid).
        return redirect_to_app(session_id, "failed")

    if action == "forge":
        # Deliberately does NOT change server state. Proves the app must not
        # trust status=paid on the redirect URL alone.
        return redirect_to_app(session_id, "paid")

    raise HTTPException(status_code=400, detail=f"unknown action '{action}'")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
