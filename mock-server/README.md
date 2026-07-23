# External Purchase Link Mock Server

Local mock of the BFF + hosted checkout site for testing Apple's
`ExternalPurchaseCustomLink` (EU external purchase link) flow before the
real Apple entitlement is available. Serves both JSON API endpoints and the
checkout HTML pages from a single FastAPI app, in-memory only.

## Setup & startup

```bash
cd mock-server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` is required so a physical device on the same Wi-Fi/LAN can
reach it — `127.0.0.1` only accepts connections from the Mac itself.

Every request is logged to stdout with a timestamp and the request body, so
you can watch the flow live while testing on device.

## Running for real device testing

### 1. Find your Mac's LAN IP

```bash
ipconfig getifaddr en0   # Wi-Fi, on most Macs
# or, if en0 isn't your active interface:
ipconfig getifaddr en1
# or, list all interfaces and pick the one matching your network:
ifconfig | grep "inet " | grep -v 127.0.0.1
```

Use that IP in your app's config, e.g. `http://192.168.1.23:8000`. Never use
`localhost`/`127.0.0.1` on the device side — that resolves to the device
itself, not your Mac.

### 2. Put device and Mac on the same network

Both need to be on the same Wi-Fi network (not one on Wi-Fi and one on
cellular/VPN). Some networks — guest Wi-Fi, coffee shops, corporate
networks, some mesh routers — enable **client/AP isolation**, which blocks
device-to-device traffic even though both show as "connected" to the same
SSID. If the LAN IP never responds from the device but works fine from the
Mac, this is the most likely cause; a personal hotspot from your phone (with
the Mac joined to it) is a reliable fallback that avoids it entirely.

### 3. Allow the firewall prompt

The first time you run `uvicorn` bound to `0.0.0.0`, macOS may pop up
"Do you want the application '**Python**' to accept incoming network
connections?" — click **Allow**. If you missed it or clicked Deny, fix it
under System Settings → Network → Firewall → Options, and allow incoming
connections for Python/uvicorn.

### 4. Allow cleartext HTTP in the app (ATS)

iOS's App Transport Security blocks plain `http://` by default — a WKWebView
load to your Mac's IP will fail even though curl works fine, since curl
doesn't enforce ATS. For local testing only, add an ATS exception to the
app's `Info.plist` scoped to your LAN IP (or `NSAllowsArbitraryLoads` if
you don't want to fuss with the exact IP each time you switch networks):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

**Remove this before shipping** — it's a test-only setting. If you skip this
step, the symptom in the app's WKWebView navigation delegate is an error
like `NSURLErrorDomain -1022` ("App Transport Security policy requires the
use of a secure connection").

### 5. Register the app's custom URL scheme

The checkout pages redirect to `immowelt://payment-complete?...`. That only
opens your app if `immowelt` is registered as a URL scheme in the app's
`Info.plist` (`CFBundleURLTypes` → `CFBundleURLSchemes`). WKWebView cannot
navigate to an unknown scheme itself — your `WKNavigationDelegate`'s
`decidePolicyFor navigationAction:` has to intercept it (since WebKit will
otherwise silently fail the navigation, with no visible error) and hand off
to `UIApplication.shared.open(_:)` or handle it in-process.

### 6. Restart discipline

`--reload` watches `main.py` for changes and restarts the process on save —
useful while iterating on the server, but it wipes all in-memory sessions,
handoffs, and web-session cookies. Avoid editing the server mid-test, or
re-create the checkout session afterward.

## Auth handoff (why the checkout URL isn't the session URL)

The iOS app loads checkout in an in-app `WKWebView`. A custom `Authorization`
header set on the first request does not propagate to subsequent
navigations, and the checkout is multi-step (order summary → payment →
confirm), so auth has to transfer into the webview some other way. This
server does it with a **one-time handoff token**:

1. `POST /checkout/session` never returns a checkout URL you can just open —
   it returns `checkout_url` pointing at `/checkout/start?handoff=<token>`,
   a redemption endpoint. A session literally cannot exist without a
   handoff.
2. `GET /checkout/start?handoff=<token>` redeems the token **exactly once**,
   atomically — a replayed request always loses, even under concurrent
   access (`checkout_start` redeems inside an `asyncio.Lock` with no
   `await` between the check and the write, so exactly one caller ever
   observes `redeemed=False`). The token is short-lived (60s TTL) and is
   bound to the specific `session_id`/`user_id` it was minted for.
3. On success, redemption sets a normal `HttpOnly`/`SameSite=Lax` session
   cookie (`eplp_session`) and 302s to `/checkout/{session_id}`. From then
   on, the webview is a normal cookie-authenticated browser session — no
   further handoff needed for `payment`/`confirm`/`action` steps.
4. On failure (expired, already redeemed, unknown token), the response is
   always an **HTML error page with HTTP 401** — never a login form. A
   login form rendered inside an app's webview is a phishing-shaped
   experience and this server is deliberately built to never produce one.
5. Every `/checkout/{session_id}*` route checks the cookie and rejects
   (401 + error page) if it's missing, or if it's a valid cookie for a
   *different* session — a handoff for session A must not open session B.

Use `POST /debug/handoff-mode` to force a specific failure deterministically
without needing to actually wait out a TTL or race a replay — see below.

## API endpoints (curl reference)

Replace `$HOST` with `http://localhost:8000` or `http://<your-lan-ip>:8000`.

```bash
HOST=http://localhost:8000
```

### `POST /tokens`

Apple's real token is a base64-encoded JSON blob containing an
`externalPurchaseId` UUID — that's the identifier Apple expects reported
back, not the raw token string. The client extracts it and sends only that;
the raw base64 token stays on-device for diagnostics and is never
transmitted here. `device_id` travels as a `Device-Id` header rather than in
the body (mirroring how `Idempotency-Key` already worked) since it's
transport-level, not part of the reported data.

```bash
# Both purchase IDs present
curl -X POST $HOST/tokens \
  -H "Content-Type: application/json" \
  -H "Device-Id: device-1" \
  -d '{"acquisition_purchase_id":"3fa85f64-5717-4562-b3fc-2c963f66afa6","services_purchase_id":"7c9e6679-7425-40de-944b-e07fc1f90ae7","acquisition_absence_reason":null,"fetched_at":"2026-07-22T10:00:00Z"}'

# Returning customer — acquisition_purchase_id is legitimately null, still 200
curl -X POST $HOST/tokens \
  -H "Content-Type: application/json" \
  -H "Device-Id: device-1" \
  -d '{"acquisition_purchase_id":null,"services_purchase_id":"7c9e6679-7425-40de-944b-e07fc1f90ae7","acquisition_absence_reason":"period_elapsed_or_not_issued","fetched_at":"2026-07-22T10:00:00Z"}'

# services_purchase_id null -> 400 (client-side token subsystem failure, must not be reported as data)
curl -X POST $HOST/tokens \
  -H "Content-Type: application/json" \
  -H "Device-Id: device-1" \
  -d '{"acquisition_purchase_id":null,"services_purchase_id":null,"fetched_at":"2026-07-22T10:00:00Z"}'
```

Resubmitting the same `(acquisition_purchase_id, services_purchase_id)` pair
for a device is naturally idempotent — the pair *is* the idempotency key
(`acq:<uuid-or-none>|svc:<uuid>`), no client-supplied idempotency header
needed. The same response is returned without reprocessing.

### `GET /tokens/acknowledged?device_id=`

```bash
curl "$HOST/tokens/acknowledged?device_id=device-1"
```

Returns the idempotency keys already acknowledged for that device:

```json
{"idempotency_keys": ["acq:3fa85f64-5717-4562-b3fc-2c963f66afa6|svc:7c9e6679-7425-40de-944b-e07fc1f90ae7"]}
```

### `GET /debug/mint-token?type=ACQUISITION|SERVICES&variant=...`

Mints a realistically-encoded mock token — base64 JSON shaped like Apple's
real `ExternalPurchaseCustomLink` token — so the client's decoder is
genuinely exercised rather than fed a hand-rolled string. **All dates in
minted tokens are epoch milliseconds**, not seconds.

```bash
curl "$HOST/debug/mint-token?type=SERVICES&variant=valid"
# => {"value": "<base64>"}
```

| `variant` | Shape | Client behavior it exercises |
|---|---|---|
| `valid` | Well-formed, unexpired, ~1 year lifetime | Baseline happy-path decode |
| `expired` | `tokenExpirationDate` in the past | Client must treat as expired rather than usable |
| `expiring_soon` | Expires in 5 minutes | Client should treat as near-expiry / prefer a refetch over relying on it |
| `base64url` | Encoded with `-`/`_`, no padding | Client's base64 normalization (base64url → standard) before JSON decode |
| `malformed_json` | Valid base64, invalid JSON inside | Client must fail closed (treat as a fetch failure), not crash |
| `invalid_base64` | Not base64 at all | Same as above — decoding itself fails before JSON is ever touched |
| `type_mismatch` | `tokenType` says the opposite of what was requested | Client must detect/reject a mismatched token rather than trusting the request's own `type` param |
| `missing_optional_fields` | No `tokenType`, no `tokenExpirationDate` | Apple documents these as custom-link-only; their absence must be tolerated, not treated as malformed |
| `unknown_extra_field` | Includes a field the client's struct doesn't know | Client must decode successfully and ignore it (forward compatibility) |

### `POST /checkout/session`

```bash
curl -X POST $HOST/checkout/session \
  -H "Content-Type: application/json" \
  -d '{"product_id":"com.example.premium.monthly","user_id":"user-1","acquisition_token":"abc123","services_token":"svc456"}'
```

```json
{
  "session_id": "...",
  "checkout_url": "http://localhost:8000/checkout/start?handoff=<token>",
  "handoff_expires_at": "2026-07-22T10:01:00+00:00",
  "expires_at": "2026-07-22T10:15:00+00:00"
}
```

`checkout_url` is the handoff redemption endpoint, not the checkout page
directly — see [Auth handoff](#auth-handoff-why-the-checkout-url-isnt-the-session-url)
above. `handoff_expires_at` is 60 seconds out; `expires_at` is the
underlying checkout session's normal 15-minute TTL, unchanged from before.

### `GET /checkout/start?handoff=<token>`

Redeems the handoff and, on success, sets the `eplp_session` cookie and
302s to `/checkout/{session_id}`. See the worked example below.

### `GET /checkout/session/{session_id}/verify`

```bash
curl $HOST/checkout/session/SESSION_ID/verify
```

This is the endpoint the app must trust as the source of truth — never the
redirect URL alone.

### `POST /debug/handoff-mode`

Forces the *next* (and all subsequent, until reset or changed again)
`/checkout/start` redemptions to deterministically fail a specific way,
without needing to actually replay a token or wait out its TTL:

```bash
curl -X POST $HOST/debug/handoff-mode \
  -H "Content-Type: application/json" \
  -d '{"mode":"expired"}'
```

| `mode` | Effect |
|---|---|
| `normal` | Real handoff logic (default) |
| `already_redeemed` | Every redemption attempt gets the "already used" error page + 401 |
| `expired` | Every redemption attempt gets the "expired" error page + 401 |
| `wrong_session` | Every redemption attempt gets the "not valid for this session" error page + 401 |
| `reject` | Every redemption attempt gets a generic "invalid link" error page + 401 |

`POST /debug/reset` sets this back to `normal`.

### `GET /debug/sessions`

```bash
curl $HOST/debug/sessions
```

### `POST /debug/sessions/{session_id}/force`

```bash
# Force into any state, e.g. to test the pending-verification path
# or race conditions without waiting on real timers
curl -X POST $HOST/debug/sessions/SESSION_ID/force \
  -H "Content-Type: application/json" \
  -d '{"status":"paid"}'
```

Valid `status` values: `pending`, `paid`, `cancelled`, `expired`.

### `POST /debug/reset`

```bash
curl -X POST $HOST/debug/reset
```

Clears all sessions, token submissions/acknowledgements, handoffs, web
session cookies, and resets `handoff-mode` back to `normal`.

## Worked examples

### Redeem a handoff twice — the second attempt must fail

```bash
RESP=$(curl -s -X POST $HOST/checkout/session \
  -H "Content-Type: application/json" \
  -d '{"product_id":"com.example.boost","user_id":"user-1"}')
echo "$RESP"
# {"session_id":"...", "checkout_url":"http://localhost:8000/checkout/start?handoff=<token>", ...}

curl -i "http://localhost:8000/checkout/start?handoff=<token>"
# HTTP/1.1 302 Found
# location: /checkout/<session_id>
# set-cookie: eplp_session=...; HttpOnly; Path=/; SameSite=lax

curl -i "http://localhost:8000/checkout/start?handoff=<token>"
# HTTP/1.1 401 Unauthorized
# <html>... "This checkout link has already been used." ...</html>
```

### Hit `/checkout/{id}` without a cookie — must 401, never a login form

```bash
curl -i $HOST/checkout/<session_id>
# HTTP/1.1 401 Unauthorized
# <html>... "You need to open this checkout from the app." ...</html>
```

The same 401 + error page fires if you present a cookie that's valid but
was issued for a *different* session — the cookie only authenticates the
one `session_id` its handoff was minted for.

## Checkout flow

`checkout_url` from `POST /checkout/session` walks through a redemption
step and then three real page loads (useful for exercising WKWebView
navigation delegate handling against more than one navigation):

1. `GET /checkout/start?handoff={token}` — one-time redemption; sets the
   session cookie, 302s onward
2. `GET /checkout/{id}` — order summary, "Proceed to Payment" (also has a
   link to `https://example.com`, to confirm the app's navigation allowlist
   opens external origins in Safari instead of the in-app webview)
3. `GET /checkout/{id}/payment` → `POST` (redirects 303) — fake card form, "Review Order"
4. `GET /checkout/{id}/confirm` — final screen with all test-scenario buttons

## Test scenarios (buttons on the confirm page)

| Button | Server-side effect | Redirect | What it tests |
|---|---|---|---|
| **Complete Purchase** | Session → `paid`, `verified_at` set | `immowelt://payment-complete?session_id={id}&status=paid` | Happy path: redirect *and* verify endpoint agree |
| **Cancel** | Session → `cancelled` | `immowelt://payment-complete?session_id={id}&status=cancelled` | User-initiated cancellation |
| **Simulate slow processing** | Session stays `pending`; a background task flips it to `paid` after a 20s delay | Immediate redirect with `status=pending` | `pendingVerification` path — app returns before the backend confirms, must poll `/verify` |
| **Simulate payment failure** | No change — session stays `pending` | `status=failed` | App must treat this as unpaid, not just log an error |
| **Redirect with forged success** | No change — session stays `pending` | `status=paid` (forged) | Proves the app refuses to trust the redirect URL and calls `/verify` before granting entitlement |

Sessions expire automatically 15 minutes after creation. A `pending` session
past its expiry reads as `expired` from `/verify` and `/debug/sessions`; a
session that already reached `paid` or `cancelled` keeps that status even
past the 15-minute mark, since the outcome already happened.

## Troubleshooting

Always start from the server's stdout — every request is logged with a
timestamp and body, so you can immediately tell whether the device's request
is even reaching the server. If a step below says "check the log" and you
see nothing at all for the action you just took on device, the problem is
network-level (steps 1–2), not app logic.

| Symptom | Likely cause | Fix |
|---|---|---|
| Device can't reach the server at all (timeout, connection refused); curl from the Mac itself works fine | Wrong host binding, or client isolation on the Wi-Fi network | Confirm you started with `--host 0.0.0.0` (not the default `127.0.0.1`). Confirm with `lsof -nP -iTCP:8000 -sTCP:LISTEN` that something is listening on `*:8000`. Then try a personal hotspot to rule out AP isolation. |
| Works on the Mac's browser via the LAN IP, but not from the device | Device and Mac aren't actually on the same network, or the LAN IP changed (DHCP re-lease) | Re-run `ipconfig getifaddr en0` — laptops get reassigned IPs after sleep/reconnect. Ping the LAN IP from the device's browser first before trying the app. |
| WKWebView shows a blank page or an ATS-related console error (`NSURLErrorDomain -1022`) | App Transport Security blocking cleartext `http://` | Add the ATS exception to `Info.plist` (see step 4 above). Check the WKWebView's navigation delegate `didFailProvisionalNavigation` callback for the actual error. |
| Tapping "Complete Purchase" does nothing / app never opens | `immowelt` URL scheme not registered, or the navigation delegate isn't intercepting it | Verify `CFBundleURLSchemes` in Info.plist includes `immowelt`. Add logging to `decidePolicyFor navigationAction:` to confirm the delegate even sees the scheme — WebKit fails silently on unhandled custom schemes, it does not raise a visible error. |
| `GET /checkout/{id}` returns 401 even right after redeeming a handoff | Cookies aren't being sent/stored by the client (e.g. testing with `curl` without `-c`/`-b`, or an `ASWebAuthenticationSession`/ephemeral session that drops cookies) | For curl, use `-c cookies.txt` on the redeem request and `-b cookies.txt` on the follow-up. In the app, make sure the checkout is loaded in a persistent `WKWebView`/`WKWebsiteDataStore`, not an ephemeral one. |
| `GET /checkout/{id}` returns 404 | Session doesn't exist — either never created, or the server restarted (state is in-memory only) | Check `/debug/sessions` for the ID. If you were using `--reload` and edited `main.py`, the restart cleared everything — create a fresh session. |
| Session shows `expired` sooner than expected | 15-minute TTL elapsed between session creation and the on-device test, or the Mac's clock is off | Check `expires_at` vs. `created_at` in `/debug/sessions`. Create a new session right before testing rather than reusing an old one from earlier in the day. |
| "Simulate slow processing" never flips to `paid` | Server restarted (via `--reload`) during the 20s window, killing the background task | Poll `/checkout/session/{id}/verify` or `/debug/sessions` a few times after clicking — if it's still `pending` well past 20s, check the log for a restart, and avoid editing files during this test. |
| Idempotency resend (`/tokens`) returns old/wrong-looking data | Working as intended — resubmitting the same `acquisition_purchase_id`/`services_purchase_id` pair returns the cached first response rather than reprocessing | `POST /debug/reset` to clear acknowledgements between test runs. |
| Confusing/stale state generally | Leftover sessions, handoffs, cookies, or cached tokens from a previous test run | `POST /debug/reset` clears sessions, token submissions/acknowledgements, handoffs, web session cookies, and `handoff-mode` in one call. |
| Need to force a specific state without waiting or clicking through the UI | — | `POST /debug/sessions/{id}/force` with `{"status": "..."}` for session status, or `POST /debug/handoff-mode` with `{"mode": "..."}` for handoff failure modes. |
