# Pip

A native iPhone baby tracker built with SwiftUI, ActivityKit, and a Cloudflare Workers + D1 backend. iOS 17 or later. No third-party iOS dependencies.

## What’s included

- Email/password signup and login, Keychain sessions, password changes and email reset codes, logout, account deletion.
- Create a family, invite caregivers by email, join with a recipient-bound single-use invitation, remove caregivers, and manage multiple babies.
- Breastfeeding timer with independent left/right totals, switch, pause/resume, and finish. Timer survives relaunch and excludes paused time.
- Interactive Lock Screen and Dynamic Island Live Activities with switch-breast and pause/resume buttons.
- Bottle feeds (breast milk or formula), pumping volume and duration, mL/US fl oz entry, past activity entry, notes, editing, and deletion.
- Daily summary, searchable/filterable history, and CSV export.
- Protected local cache, persistent offline mutation queue, immediate local controls, immediate family updates over WebSockets, an eight-second fallback sync, and automatic merging of independent edits.
- Light/dark appearance, native text scaling and accessibility labels, large controls, and a custom app icon.

## Run locally

Requirements: Xcode with an iOS simulator, Node 22+, and optionally XcodeGen (the generated project is checked in).

```sh
cd backend
npm ci
npm run db:local
npm run dev
```

Open `ios/Pip.xcodeproj`, choose the **Pip** scheme and an iPhone simulator, and run. Debug simulator builds automatically use `http://127.0.0.1:8787`; physical devices and Release builds use `https://api.mypip.baby`. No environment variable is needed. Create an account and family in the app. Local auth, tracking, and sync are real, backed by local D1. Keep `npm run dev` running while using the Debug simulator. The stable `preview_database_id` preserves the local database independently of the production D1 ID; do not change it when deploying.

Invitations and password resets use Cloudflare Email Service from `noreply@mypip.baby`. Local development simulates delivery in Wrangler; it does not send real email. Password-reset responses avoid revealing account existence.

After editing `ios/project.yml`, regenerate with:

```sh
xcodegen generate --spec ios/project.yml
```

## Checks

```sh
cd backend
npm run typecheck
npm test
npm audit
```

In Xcode, Product → Test runs the timer tests. The local integration test also runs if a Worker is listening at the default loopback endpoint and the simulator has no existing signed-in user. It creates temporary accounts, exercises auth/family/feeds/bottles/pumping/persistence, and deletes its test account. It skips remote endpoints and existing simulator sessions.

Command-line example (replace the destination with an installed simulator):

```sh
xcodebuild -project ios/Pip.xcodeproj -scheme Pip \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ios/DerivedData CODE_SIGN_IDENTITY=- test
```

Backend tests run in the actual local Workers runtime with D1 migrations. They cover session revocation, family isolation, invite restrictions, optimistic concurrency, idempotent retries, active-feed uniqueness, validation, password resets, and deletion.

## Production deployment

The production API is configured at `https://api.mypip.baby` using Cloudflare Workers and D1. See [deployment instructions](docs/DEPLOYMENT.md) for updates and email sender setup. Local and production sessions and offline data are stored separately.

## Important scope details

- Live Activity buttons execute `LiveActivityIntent` in the app process and update local storage and ActivityKit immediately. They do not need an App Group. Real-device, signed-build verification is still required for lock-screen button dispatch and background execution.
- Family-scoped Durable Objects notify open apps immediately. With APNs credentials configured, the Worker starts, updates, and ends breastfeeding Live Activities on each signed-in family device, including locked phones. iOS 17.2+ is required. Apple delivery and Live Activity permissions/lifecycle limits still apply; physical-device verification is required.
- Sync currently fetches the family history in pages of 500 and merges by record ID. This is deliberately simple for family-sized data. Large histories should gain a server sequence/change-feed endpoint before scaling.
- One active activity per baby and kind is enforced in D1. Concurrent starts join the existing timer. Timer controls are persisted, target-state commands: two caregivers pressing Pause cannot resume the timer. Retries are deduplicated, older timer commands cannot undo newer controls, and late commands cannot reopen finished activities. Disjoint history edits merge; competing edits to the same detail still require review.
- A family has one owner. Owners can invite/remove caregivers. Members can leave by removing themselves. Ownership transfer and joining multiple families are not implemented.
- There is no mandatory signup email-verification flow. Invitation acceptance requires both the addressed account and the secret sent in the email.
- D1 and local OS file protection protect stored data; this is not end-to-end encryption. Configure production retention, privacy policy/support URLs, and App Store privacy disclosures before distribution.

## Layout

- `ios/Pip`: SwiftUI screens, networking, Keychain, persistence, and sync.
- `ios/Shared`: Codable models, timer state machine, Live Activity attributes and intents.
- `ios/PipWidgets`: Lock Screen and Dynamic Island rendering.
- `ios/PipTests`: timer tests and optional local integration test.
- `backend/src`: Hono API, authorization, validation, password hashing.
- `backend/migrations`: D1 schema and constraints.
- `backend/test`: runtime integration tests.

Design previews from the simulator are in `docs/screenshots/`.
