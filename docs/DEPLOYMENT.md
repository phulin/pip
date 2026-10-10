# Production setup

## Cloudflare

1. Create/select your Cloudflare account. Enable Workers Paid for outbound transactional email to arbitrary recipients and sufficient CPU for password hashing. No account or paid plan is created by this repository.
2. In `backend`, run `npx wrangler login`. The production account and `pip-db` database ID are configured in `wrangler.jsonc`.
3. The Worker custom domain is `api.mypip.baby`. Wrangler manages its DNS and TLS certificate.
4. Email Sending uses `mypip.baby`, with `noreply@mypip.baby` as the sender. Check domain status with `npx wrangler email sending settings mypip.baby` and DNS with `npx wrangler email sending dns get mypip.baby`.
5. The `EMAIL` send binding, `EMAIL_FROM`, and password-hashing CPU limit are checked into `wrangler.jsonc`. Local development uses simulated email delivery; no remote email binding is enabled for local tests.
6. Run `npm ci`, `npm run typecheck`, and `npm test`.
7. Run `npm run db:remote` and then `npm run deploy`. Wrangler deploys to `https://api.mypip.baby`; the `workers.dev` endpoint is disabled.
8. Request `/health` and verify it returns `{ "status": "ok", "service": "pip" }`. Then test signup, login, invitation delivery/acceptance, password reset, and two-device synchronization with test accounts. Rate limiting is 10 auth requests per IP per minute, plus per-email login limits and per-user invitation/join limits.

Do not put Cloudflare API tokens, session tokens, or email credentials in the iOS app. Workers uses D1 and Email Service bindings; no email API secret is needed. The scheduled handler removes expired sessions, invites, and reset tokens daily.

Cloudflare references: [D1 setup](https://developers.cloudflare.com/d1/get-started/), [Email Sending setup](https://developers.cloudflare.com/email-service/get-started/send-emails/), [Email Workers API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/), [Email plan requirements](https://developers.cloudflare.com/email-service/platform/pricing/).

## Apple / iOS

1. Set your Apple development team in `ios/project.yml` (`DEVELOPMENT_TEAM`). Replace `app.pip.baby` and `app.pip.baby.widgets` with your registered, unique bundle IDs.
2. API selection is automatic: **Debug simulator** builds use `http://127.0.0.1:8787`; **physical devices and all Release builds** use `https://api.mypip.baby`. No environment variable or build setting is needed. Local and production Keychain sessions and offline caches are separate. A stopped local server produces a connection error rather than silently switching to production.
3. Run `xcodegen generate --spec ios/project.yml`. Open the project and confirm signing for both Pip and PipWidgets.
4. Run on a physical iPhone. Start a feed, lock the phone, tap switch and pause/resume, unlock, and verify side totals, paused intervals, local persistence, and cloud records. Also test airplane mode and relaunch.
5. Configure APNs as described below, then test a second caregiver on a second device. Open apps update over authenticated WebSockets, with an eight-second polling fallback. Locked phones receive Live Activity pushes. Both users must have launched the app, signed in, and allowed Live Activities.
6. Archive a Release build, complete App Store privacy details and support/privacy-policy URLs, and distribute through TestFlight.

Live Activities are declared through `NSSupportsLiveActivities` in the app and a WidgetKit extension. The timer uses system-rendered dates, so it keeps displaying elapsed time without a per-second background task. iOS imposes lifecycle limits on Live Activities; the app’s persisted feed remains authoritative after a Live Activity expires.

Apple reference: [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

## Family Live Activity push setup

Enable Push Notifications for the `app.pip.baby` App ID in the Apple Developer account, and refresh its provisioning profiles. `Pip/Pip.entitlements` contains the development entitlement; Xcode distribution signing selects the production environment. Keep automatic signing configured for both targets. The minimum OS is iOS 17.2 for push-to-start support.

Create an APNs signing key (.p8), then configure these **Worker secrets** from `backend`:

```sh
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_PRIVATE_KEY < /absolute/path/to/AuthKey_KEYID.p8
```

The team currently used locally is `W36EA63J6V`; the key must belong to the signing team. Do not commit the .p8 file. Relaunch signed apps after enabling the secrets so devices register again. Debug device builds register sandbox tokens; Release/TestFlight register production tokens. Debug simulators use the local API and local Live Activities without remote APNs.

The Cloudflare `FAMILY_ROOMS` Durable Object handles WebSocket fan-out and a persistent push retry queue. The Worker signs APNs requests directly; no third-party push service is involved. APNs credentials are currently a deployment prerequisite, not supplied by the repository. Registration reports whether delivery is configured; without credentials, open apps still display local Live Activities for synced family feeds.

Verification on **two physical phones**:

1. Sign in as separate members of one family. Start a feed on phone A while B is locked. Check that both display the same Live Activity.
2. Tap switch on B; A must show the requested side and preserve the elapsed total. Press Pause on both at once; the timer must remain paused.
3. Resume and finish on either phone. Both Live Activities should end on finish.
4. Disconnect A, queue a control, finish on B, then reconnect A. The ended feed must stay ended. Test sign-out and member removal: neither device may receive new family data after its access is revoked.
5. Verify TestFlight as well as a development-signed build, because APNs environments differ.

Backend tests cover two-caregiver races, WebSocket delivery/revocation, merging, duplicate starts, token ownership, APNs signing/payloads, retries and token rejection. APNs transport is mocked in tests; those tests cannot establish physical-device delivery. Apple can delay, deny or end Live Activities, so push delivery is not an absolute guarantee.

Apple reference: [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

## API overview

All `/v1` routes require `Authorization: Bearer <session>`. Session secrets are random 256-bit values, stored as SHA-256 hashes in D1; passwords use salted scrypt (N=16384, r=8, p=5). Tokens expire after 30 days. Auth bodies are capped at 32 KiB, activity notes at 2,000 characters. All family routes derive the family from the authenticated membership rather than trusting a submitted family ID.

| Route | Purpose |
| --- | --- |
| `POST /auth/register`, `/auth/login` | Return session and user |
| `POST /auth/forgot-password`, `/auth/reset-password` | Email recovery / single-use reset |
| `GET /v1/me` | Current user and family |
| `POST /v1/logout`, `/v1/password` | Revoke session / change password |
| `POST /v1/families`, `/v1/join` | Create family / accept emailed code |
| `GET /v1/family/members` | Family caregiver list |
| `DELETE /v1/family/members/:id` | Remove caregiver / leave |
| `POST /v1/family/invites` | Send recipient-bound invitation |
| `GET/POST /v1/family/babies` | List / add babies |
| `GET /v1/family/activities?cursor=...` | Full history in pages, including tombstones |
| `PUT /v1/family/activities/:id` | Versioned idempotent upsert or tombstone |
| `POST /v1/family/activities/:id/commands` | Idempotent target-side, pause, finish, and volume commands |
| `GET /v1/family/live` | Authenticated family WebSocket (upgrade required) |
| `PUT /v1/family/devices/:id` | Register push-to-start token for this session |
| `PUT /v1/family/devices/:id/activities/:activityId` | Register per-activity update token |
| `DELETE /v1/account` | Password-confirmed account deletion |

Mutation payloads carry `revision` and `mutationId`. Retries of an accepted mutation return its current version without duplication. A stale revision with a `base` snapshot merges disjoint changes; competing edits to the same field group return HTTP 409. Commands use durable receipts, so retrying an old command returns the latest state without applying it twice. Successful writes increment the revision. Different families cannot read or mutate one another’s baby/activity records. Activity kind and baby identity are immutable after creation.
