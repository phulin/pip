# Production setup

## Cloudflare

1. Create/select your Cloudflare account. Enable Workers Paid for outbound transactional email to arbitrary recipients and sufficient CPU for password hashing. No account or paid plan is created by this repository.
2. In `backend`, run `npx wrangler login` then `npx wrangler d1 create pip-db`.
3. Replace the placeholder database UUID in `backend/wrangler.jsonc` with the returned ID. If multiple accounts are available, add your `account_id` explicitly.
4. Onboard your domain under **Email Service → Email Sending**. Wait for sender DNS verification.
5. Add these top-level keys to `wrangler.jsonc`, using your real verified domain:

```json
{
  "send_email": [{ "name": "EMAIL" }],
  "vars": { "EMAIL_FROM": "care@YOUR-VERIFIED-DOMAIN" },
  "limits": { "cpu_ms": 5000 }
}
```


6. Run `npm ci`, `npm run typecheck`, and `npm test`.
7. Run `npm run db:remote` and then `npm run deploy`. Wrangler prints the public HTTPS `workers.dev` endpoint. A custom API domain is optional.
8. Request `/health` and verify it returns `{ "status": "ok", "service": "pip" }`. Then test signup, login, invitation delivery/acceptance, password reset, and two-device synchronization with test accounts. Rate limiting is 10 auth requests per IP per minute, plus per-email login limits and per-user invitation/join limits.

Do not put Cloudflare API tokens, session tokens, or email credentials in the iOS app. Workers uses D1 and Email Service bindings; no email API secret is needed. The scheduled handler removes expired sessions, invites, and reset tokens daily.

Cloudflare references: [D1 setup](https://developers.cloudflare.com/d1/get-started/), [Email Sending setup](https://developers.cloudflare.com/email-service/get-started/send-emails/), [Email Workers API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/), [Email plan requirements](https://developers.cloudflare.com/email-service/platform/pricing/).

## Apple / iOS

1. Set your Apple development team in `ios/project.yml` (`DEVELOPMENT_TEAM`). Replace `app.pip.baby` and `app.pip.baby.widgets` with your registered, unique bundle IDs.
2. Set `PIP_API_URL` to the deployed **HTTPS** API URL. The checked-in loopback default is for the simulator only.
3. Run `xcodegen generate --spec ios/project.yml`. Open the project and confirm signing for both Pip and PipWidgets.
4. Run on a physical iPhone. Start a feed, lock the phone, tap switch and pause/resume, unlock, and verify side totals, paused intervals, local persistence, and cloud records. Also test airplane mode and relaunch.
5. Test a second caregiver on a second device. Foreground updates should appear within roughly eight seconds; background devices refresh on resume. There are no APNs pushes in this version.
6. Archive a Release build, complete App Store privacy details and support/privacy-policy URLs, and distribute through TestFlight.

Live Activities are declared through `NSSupportsLiveActivities` in the app and a WidgetKit extension. The timer uses system-rendered dates, so it keeps displaying elapsed time without a per-second background task. iOS imposes lifecycle limits on Live Activities; the app’s persisted feed remains authoritative after a Live Activity expires.

Apple reference: [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

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
| `DELETE /v1/account` | Password-confirmed account deletion |

Mutation payloads carry `revision` and `mutationId`. Retries of an accepted mutation return its current version without duplication. A stale revision returns HTTP 409. Successful writes increment the revision. Different families cannot read or mutate one another’s baby/activity records. Activity kind and baby identity are immutable after creation.
