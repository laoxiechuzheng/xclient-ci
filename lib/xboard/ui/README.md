# XClient account UI

The authenticated UI has its own Navigator. `XcCommerceHost` wraps that Navigator,
so pages opened from plans, account orders and gift cards share one login's panel
currency and entitlement refresh coordinator. Currency comes from
`commConfig.currency_symbol` and `currency`; absent configuration defaults to CNY.
No mutable currency is shared across sessions. All displayed amounts are cents;
the legacy `getSubscribe.plan.prices.reset_traffic` field is converted from major
currency units before display.

`order/checkout` acknowledges a payment action. In particular, `type=-1` can mean
balance payment was accepted while provisioning is still in progress. The panel
uses `0=pending`, `1=processing`, `2=cancelled`, `3=completed`, `4=discounted`.
An order page polls pending and processing every three seconds while visible,
for up to thirty minutes. After that the user can refresh or reopen the order.
Only completed orders trigger the injected `refreshUser` then `syncNow` callback.
Successful refreshes are deduplicated by trade number within the login; failed
refreshes remain retryable. Completed gift-card redemptions use the same callback.
The callback preserves the central subscription admission and rate limits, and
checks the login generation before starting subscription synchronization.
If a recent or already-running pull predates completion, a deferred request uses
the same central cooldown and admission retry schedule.

`flutter test --no-pub test/xboard/ui` covers payment transitions, retry,
session route disposal, configured currencies, and mobile/desktop rendering.
Set `XC_UI_SCREENSHOTS` to a local directory to retain the rendering evidence.
Tests render fake data without starting the network core or system proxy.

Visual conventions, tokens, components and motion rules are in `DESIGN-SYSTEM.md`.
`test/xboard/ui/visual_test.dart` renders every core screen at four sizes in light
and dark themes; with `XC_UI_SCREENSHOTS` set it also writes the screenshots.
