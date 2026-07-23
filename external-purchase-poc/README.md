# External Purchase Link — SwiftUI + TCA prototype

A prototype of Apple's EU **External Purchase Link** flow
(`ExternalPurchaseCustomLink`), built and fully testable **without** the
real entitlement:

- [`../mock-server/`](../mock-server) — a FastAPI server playing both
  roles a real integration needs: the merchant's BFF (`/tokens`,
  `/checkout/session`, `/checkout/session/{id}/verify`) and the hosted
  checkout website itself.
- [`ios-app/`](ios-app) — a SwiftUI + [The Composable
  Architecture](https://github.com/pointfreeco/swift-composable-architecture)
  app, split into a reusable package and a thin demo target.

Every StoreKit touchpoint is hidden behind a `@DependencyClient`
(`ExternalPurchaseClient`) whose `liveValue` is a **mock**. Swapping in the
real `ExternalPurchaseCustomLink` API later means rewriting that one file —
nothing else in the app changes. See
["What changes when the real entitlement arrives"](#what-changes-when-the-real-entitlement-arrives)
below.

> The original `external-purchase-poc/backend/` + `ASWebAuthenticationSession`
> proof of concept has been superseded by this package. `backend/` is left
> in place but unused — point the app at `../mock-server/` instead, which
> implements the richer BFF contract (tokens, sessions, verify, debug
> endpoints, forged-redirect test case) this version relies on.

## Project layout

```
ios-app/
  ExternalPurchaseKit/              ← local SPM package, the actual deliverable
    Sources/ExternalPurchaseKit/
      Models/                       TokenState, PurchaseOutcome, DTOs, ...
      Clients/                      ExternalPurchaseClient, BFFClient
      Persistence/                  @Shared key definitions
      Features/                     CheckoutFeature, WebCheckoutFeature,
                                     ExternalPurchaseLifecycleFeature
      UI/                           ExternalPurchaseButton, CheckoutSheetView,
                                     CheckoutWebView (WKWebView), NoticeSheetView
      Config/                       ExternalPurchaseKitConfig (base URL, etc.)
    Tests/ExternalPurchaseKitTests/ TCA TestStore tests — zero network, zero StoreKit
  ExternalPurchasePOC/               ← thin demo app target
    App/                            App entry, AppFeature (root reducer)
    Features/                       PaywallFeature, DebugMenuFeature
    Views/                          RootView, PaywallView, DebugMenuView, EventLogView
    Config/                         AppConfig (points the package at a server)
  Project.yml                       XcodeGen spec (regenerates the .xcodeproj)
```

## How the flow fits together

```
ExternalPurchaseButton (UI)
        │ .buttonTapped
        ▼
CheckoutFeature state machine
  idle → checkingEligibility → preparingSession → presentingNotice
       → presentingWebView → verifying → terminal(PurchaseOutcome)
        │                              │
        │ ExternalPurchaseClient       │ BFFClient
        │ (mock StoreKit)              │ (real network → mock-server)
        ▼                              ▼
  isEligible / token / showNotice   createCheckoutSession / verifySession
```

- `ExternalPurchaseClient.showNotice` presents its own SwiftUI sheet
  imperatively (`NoticeSheetPresenter`), outside of any TCA navigation
  state — mirroring how Apple's real disclosure sheet is presented and
  dismissed by the system itself, not by app code.
- The web checkout is a genuine `@Presents` child feature
  (`WebCheckoutFeature`) so `CheckoutFeature` can drive it, and so
  `TestStore` can simulate every dismissal path without a real `WKWebView`.
- **Every** dismissal of the checkout sheet — a redirect, Done, Cancel, or
  swipe-to-dismiss — funnels through the same `verify` step, which calls
  `GET /checkout/session/{id}/verify` before deciding anything. The
  redirect URL's query string is never inspected at all, by design (see
  `CheckoutWebView`'s navigation delegate) — only its scheme+host is used
  as a signal that the checkout finished.

## Running it

### 1. Start the mock server

```bash
cd mock-server
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
./.venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` is required for a physical device to reach it later;
Simulator works fine against `127.0.0.1`/`localhost` either way. Every
request is logged to stdout with a timestamp — useful for watching the flow
live while testing.

### 2. Generate and open the Xcode project

```bash
brew install xcodegen   # if you don't have it
cd ios-app
xcodegen generate
open ExternalPurchasePOC.xcodeproj
```

The project is generated from `Project.yml` rather than checked in raw, so
it regenerates cleanly. It declares two package dependencies: the local
`ExternalPurchaseKit` and the remote `swift-composable-architecture`.

### 3. Point the app at your server

The base URL is a **single editable constant**, set once at launch in
[`ExternalPurchasePOC/Config/AppConfig.swift`](ios-app/ExternalPurchasePOC/Config/AppConfig.swift):

```swift
#if targetEnvironment(simulator)
static let backendBaseURL = URL(string: "http://localhost:8000")!
#else
static let backendBaseURL = URL(string: "http://192.168.1.23:8000")!  // EDIT ME for device testing
#endif
```

- **Simulator**: no edits needed — it shares the Mac's network stack, so
  `localhost` reaches the server directly.
- **Physical device**: edit the device branch to your Mac's LAN IP (find it
  with `ipconfig getifaddr en0`), make sure the server is bound to
  `0.0.0.0` (step 1 already does this), and put the device on the same
  Wi-Fi network as the Mac. `AppConfig.configureExternalPurchaseKit()`
  (called once from `ExternalPurchasePOCApp.init`) applies this to
  `ExternalPurchaseKitConfig.baseURL`, which every dependency client's
  `liveValue` reads from.

`AppConfig` also sets `ExternalPurchaseKitConfig.returnURLScheme` /
`.returnURLHost` to `immowelt` / `payment-complete`, matching the mock
server's `APP_URL_SCHEME`.

### 4. The ATS exception for local HTTP

iOS blocks plain `http://` by default. `Info.plist` already scopes an
exception to local networking only (not a blanket
`NSAllowsArbitraryLoads`):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

If you switch to a LAN IP for device testing and see `NSURLErrorDomain
-1022` in `CheckoutWebView`'s navigation delegate, this is the setting to
widen (`NSAllowsArbitraryLoads`, test builds only — remove before shipping).

### 5. The custom URL scheme

`CFBundleURLTypes` registers `immowelt` in `Info.plist`. In this mock flow
the redirect is actually intercepted *inside* `CheckoutWebView`'s
`WKNavigationDelegate` before it ever reaches iOS's URL routing — WebKit
would otherwise silently fail to navigate to an unregistered scheme, so the
registration exists for parity with the real flow (where the redirect
really does leave the app and come back via `.onOpenURL`).

### 6. Run it

⌘R in Xcode with the mock server running. Tap **Buy** on the Store tab:
eligibility check → notice sheet → web checkout (three real page loads:
order summary → payment form → confirm) → verify → unlocked. Watch the
**Event Log** tab for a timestamped trace of every state transition, and
the debug menu (ladybug icon, top-right) for runtime controls.

## Debug menu

- **Eligible for external purchase** — toggles the mock's `isEligible`.
- **Acquisition token available** — off by default (simulates a returning
  customer, for whom Apple legitimately vends no ACQUISITION token). Turn
  it on to see the first-time-acquisition path.
- **Force token fetch failure** — makes `token(_:)` throw, for exercising
  the failure path without editing code.
- **Token State** — read-only view of the current ACQUISITION `TokenState`.
- **Pending Sessions** — sessions persisted via `@Shared(.fileStorage)`
  that haven't been confirmed yet (see cold-start recovery below).
- **Hit `/debug/reset`** — clears the server's in-memory sessions, token
  submissions, and idempotency cache.

## Testing each scenario

### Automated (TCA `TestStore`, zero network, zero StoreKit)

```bash
cd ios-app/ExternalPurchaseKit
swift package resolve
xcodebuild test -scheme ExternalPurchaseKit -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation -skipPackagePluginValidation
```

(`-skipMacroValidation` avoids an interactive "trust this macro plugin"
prompt the first time; safe for these well-known pointfreeco packages.
`swift test` also works but builds for macOS, not iOS — the package only
declares iOS as a platform, so drive it through `xcodebuild` against a
Simulator destination.)

`ExternalPurchaseKitTests` covers, purely at the reducer level:

| Scenario | Test |
|---|---|
| Happy path (redirect → paid → completed) | `CheckoutFeatureTests.happyPath` |
| Notice declined | `CheckoutFeatureTests.noticeDeclined` |
| User cancels web view (Cancel tapped, no redirect) | `CheckoutFeatureTests.userCancelsWebView` |
| Forged-success redirect correctly rejected | `CheckoutFeatureTests.forgedSuccessRedirectIsRejected` |
| Pending verification (async/slow settlement) | `CheckoutFeatureTests.pendingVerification` |
| Token fetch failure | `CheckoutFeatureTests.tokenFetchFailure` |
| Ineligible user | `CheckoutFeatureTests.ineligibleUser` |
| Cold-start reconciliation (resolved + still-pending) | `ExternalPurchaseLifecycleFeatureTests.coldStartReconciliation*` |
| Returning customer ⇒ not an error | `ExternalPurchaseLifecycleFeatureTests.returningCustomerAcquisitionTokenIsNotAnError` |

Tests run non-exhaustively for `@Shared` field assertions and each give
themselves a private, isolated `.inMemory`/`.fileStorage` backing store
(`defaultFileStorage = .inMemory`, `defaultInMemoryStorage =
InMemoryStorage()`) — Swift Testing runs `@Test`s concurrently by default,
and those keys otherwise resolve to a shared ambient store, which causes
cross-test pollution. If you add a test touching `@Shared` state, copy that
pattern.

### Manual, against the live mock server

The confirm-page test-scenario buttons map directly onto the same code
paths:

| Mock server button | Exercises |
|---|---|
| **Complete Purchase** | Happy path |
| **Cancel** | Server-confirmed cancellation (`status=cancelled` from `/verify`) |
| **Simulate slow processing** | `pendingVerification` — app returns before the backend confirms |
| **Simulate payment failure** | Session stays `pending`; app must not treat it as paid |
| **Redirect with forged success** | Forged `status=paid` in the URL; `/verify` still says `pending` — app must reject it |

To test **cold-start recovery**: tap Buy, get to the web checkout, then
force-quit the app (Simulator: Device → Home, then swipe up and remove
it — or `xcrun simctl terminate booted com.example.externalpurchasepoc`)
*before* tapping anything on the confirm page. Relaunch — the debug menu's
Pending Sessions list will show the orphaned session, and the paywall shows
a "Checking for a pending purchase…" spinner while `ExternalPurchaseLifecycleFeature`
reconciles it against `/verify` before the Buy button becomes available
again. Use the server's `POST /debug/sessions/{id}/force` (see
[`mock-server/README.md`](../mock-server/README.md)) to flip that orphaned
session to `paid` first, to see reconciliation actually unlock content on
relaunch.

## What changes when the real entitlement arrives

Everything is isolated behind
[`ExternalPurchaseKit/Sources/ExternalPurchaseKit/Clients/ExternalPurchaseClient.swift`](ios-app/ExternalPurchaseKit/Sources/ExternalPurchaseKit/Clients/ExternalPurchaseClient.swift).
`liveValue` there has a `TODO:` block with a sketch of the real calls. In
order:

1. Enroll in Apple's External Purchase Link entitlement program and get
   `com.apple.developer.storekit.external-purchase-link` added to the
   app's entitlements file and provisioning profile.
2. Add `SKExternalPurchaseCustomLinkRegions` to `Info.plist`, listing the
   EU storefront region codes this app is approved for.
3. Register your real checkout domain with Apple as part of the
   entitlement request — it must match exactly what you pass to the API.
4. Rewrite `ExternalPurchaseClient.liveValue`:
   - `isEligible` / `token(_:)` call the real `ExternalPurchaseCustomLink`
     token APIs instead of returning mock values.
   - `showNotice` mostly disappears: the real disclosure sheet is
     presented and dismissed by the system automatically the moment you
     call the link-opening API — `CheckoutFeature` would call
     `ExternalPurchaseCustomLink.open(url)` directly rather than awaiting
     a separate `showNotice` step.
5. **`BFFClient`, `CheckoutFeature`'s state machine, `WebCheckoutFeature`,
   the "always verify, never trust the redirect" rule, and session
   persistence/reconciliation do not change.** The real flow leaves the app
   entirely rather than opening an in-app `WKWebView`, but it returns the
   same way — a redirect to your registered checkout domain, or the
   `immowelt://` scheme via `.onOpenURL` — and the server-side `/verify`
   call remains the only source of truth for whether payment happened.
6. `ExternalPurchaseButton`'s state machine and the debug-menu-driven
   `MockExternalPurchaseSettings` knobs go away with the mock; everything
   downstream of `.delegate(.outcome(_:))` (what the host app unlocks) is
   unaffected, since the package never owned entitlement state to begin
   with.
