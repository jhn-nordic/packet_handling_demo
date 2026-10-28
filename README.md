# Nordic SmartParcel — PocketBase edition

A self-hostable version of the SmartParcel package-handling demo. A Thingy:91 X classifies
how a parcel is handled (idle, carrying, in car, shaking, impact, free fall, placed) with an
on-device Neuton AI model, nRF Cloud forwards the results via the **Message Routing Service
(MRS)**, and a live dashboard shows them in real time.

Everything server-side is one Docker container: [PocketBase](https://pocketbase.io) (SQLite +
REST + realtime) with a small JS hook that receives the nRF Cloud webhook and serves the
dashboard. Deploy it to Fly.io in a few minutes, point your own nRF Cloud team at it, done.

```
Thingy:91 X ── LTE-M/NB-IoT ──► nRF Cloud ── MRS webhook (HTTPS) ──► PocketBase on Fly.io
                                                                     │  pb_hooks/nrfcloud.pb.js
                                                                     │   verify → decode → store
                                                                     ▼
                                           browser ◄── realtime ── classifications
                                         (dashboard served from pb_public/)
```

## What's in the box

| Path | What it does |
|---|---|
| `pocketbase/pb_hooks/nrfcloud.pb.js` | `POST /api/nrfcloud/webhook`: MRS verification, token + HMAC signature check, dedupe, stores messages, extracts classifications |
| `pocketbase/pb_hooks/lib/nrfcloud.js` | base64 / CBOR decoding and firmware-label → state mapping (same logic as the Supabase edge functions) |
| `pocketbase/pb_migrations/` | Creates the `devices`, `raw_messages` and `classifications` collections |
| `pocketbase/pb_public/index.html` | The dashboard (single HTML file, served at `/`) |
| `Dockerfile`, `docker-compose.yml` | Container image and local run |
| `fly.toml`, `scripts/fly-deploy.sh` | Fly.io deployment |
| `scripts/mrs.sh` | Create, verify, test and delete the MRS destination on **your** nRF Cloud team |
| `scripts/send-test.sh` | Sends fake signed nRF Cloud deliveries, so you can demo without a device |

### Differences from the Supabase version

- **No device whitelist.** Every device on the nRF Cloud team that MRS routes to the destination is accepted.
- **Device filter.** When more than one device has reported, a **Device** selector appears in the
  dashboard header. Choosing a device resets the session and shows only that device. The choice
  is kept in the URL (`/?device=<device-id>`), so you can bookmark a booth screen per parcel. With
  "All devices" selected, every timeline entry is tagged with the device it came from.
- One service instead of two edge functions plus a database webhook. Raw messages are pruned
  after `RAW_RETENTION_DAYS` (default 7).

## Prerequisites

- An nRF Cloud team where you are **Admin or Owner**, plus its REST API key
  (nrfcloud.com → User Account → API key). A Developer plan includes one free MRS destination.
- A Thingy:91 X running the SmartParcel firmware, or use `scripts/send-test.sh`.
- `docker`, `curl`, `jq`, `openssl`, and for Fly.io [`flyctl`](https://fly.io/docs/flyctl/install/).

## Quick start: Fly.io

```sh
cp .env.example .env
# edit .env: NRFCLOUD_API_KEY, FLY_APP (globally unique), PB_ADMIN_EMAIL, PB_ADMIN_PASSWORD

fly auth login
scripts/fly-deploy.sh      # creates the app + volume, generates webhook token/secret, deploys
scripts/mrs.sh create      # creates the MRS destination → https://$FLY_APP.fly.dev/api/nrfcloud/webhook
```

`mrs.sh create` waits until nRF Cloud reports the destination as **verified**. Then open
`https://<FLY_APP>.fly.dev/` and move the parcel.

No device at hand? Run `scripts/send-test.sh --demo`, which plays a journey from two fake parcels
so you can also see the device filter.

What `fly-deploy.sh` does (it's safe to re-run, for example after changing the dashboard):

1. Generates `NRFCLOUD_WEBHOOK_TOKEN` and `NRFCLOUD_WEBHOOK_SECRET` into `.env` if they're empty.
2. Looks up your team ID with the API key and saves it as `NRFCLOUD_TEAM_ID`.
3. Creates the Fly app and a 1 GB volume `pb_data` in `FLY_REGION`.
4. Sets the values above (and the admin login) as Fly secrets, then runs `fly deploy --ha=false`.

The app runs on a single `shared-cpu-1x` / 256 MB machine that is always on. That's a few US
dollars per month; see [Fly pricing](https://fly.io/docs/about/pricing/). SQLite lives on the
volume, so there is exactly one machine. Don't scale it out.

## Local run (Docker)

```sh
cp .env.example .env          # NRFCLOUD_WEBHOOK_TOKEN/SECRET can stay empty for local tests
docker compose up --build     # → http://localhost:8090  (admin: http://localhost:8090/_/)
scripts/send-test.sh --demo   # in another terminal
```

To receive real device data locally, expose the container through an HTTPS tunnel and point MRS
at it:

```sh
cloudflared tunnel --url http://localhost:8090     # or: ngrok http 8090
scripts/mrs.sh create https://<random>.trycloudflare.com
```

Set the token, secret and `NRFCLOUD_TEAM_ID` in `.env` before `docker compose up`, so the
container and the destination share the same credentials. `mrs.sh team` fills in the team ID.

## Managing the MRS destination

```sh
scripts/mrs.sh status          # verified? recent delivery errors?
scripts/mrs.sh list            # all destinations on the team
scripts/mrs.sh test            # nRF Cloud sends a test message
scripts/mrs.sh resend          # new verification PIN …
scripts/mrs.sh verify 123456   # … and confirm it
scripts/mrs.sh delete
```

- The destination is found by name: `MRS_DESTINATION_NAME`, default `smartparcel-<FLY_APP>`.
  Running `create` again updates the URL, token and secret instead of creating a duplicate.
- **Verification.** nRF Cloud POSTs a verification message as soon as the destination is created.
  The webhook echoes `x-nrfcloud-team-id`, so verification is automatic when `NRFCLOUD_TEAM_ID`
  is set on the server. Otherwise the webhook logs the PIN; get it with
  `fly logs | grep PIN` and run `scripts/mrs.sh verify <PIN>`.
- **Authentication.** Each delivery carries the token in `x-api-key` and an HMAC-SHA256 of the raw
  body in `x-nrfcloud-signature`. The webhook checks both whenever the matching env var is set.
- **Filtering.** The destination only receives the `device_messages` and `shadow` categories by
  default, so you aren't billed for location or FOTA traffic the demo ignores. Change this with
  `MRS_CATEGORIES=location,device_messages scripts/mrs.sh create`, or route everything with
  `MRS_CATEGORIES=`.
- API reference: <https://docs.message-routing.nrfcloud.com> ·
  Docs: <https://docs.nrfcloud.com/docs/nrfcloud/message-routing>

## Message format

The firmware sends a device message with `appId: "DETECTION"`:

```json
{ "appId": "DETECTION", "messageType": "DATA", "data": "{\"classification\":\"Carrying\",\"probability\":92}" }
```

The webhook also accepts `data` as base64-encoded JSON, as an object, or in a shadow update
(`PATCH /state/reported` with `reported.neuton` / `reported.classify`). Firmware labels map to these states:

| Firmware label | State | Severity |
|---|---|---|
| `Idle`, `Carrying`, `in Car`, `Placed` | `idle`, `carrying`, `car`, `placed` | OK |
| `Shaking` | `shaking` | Warning (quality −4) |
| `Impact`, `Free Fall` | `impact`, `freefall` | Alert (quality −12 / −10) |

`probability` is a percentage from 0 to 100. To get full probability bars, add an optional
`probabilities` map such as `{"Idle": 2, "Carrying": 92, …}`.

## Data model (PocketBase admin UI at `/_/`)

| Collection | Access | Fields |
|---|---|---|
| `devices` | public read | `device_id`, `name` (optional friendly name shown in the filter), `last_seen` |
| `classifications` | public read + realtime | `device_id`, `state`, `confidence` (0–1), `probabilities` |
| `raw_messages` | admin only | `device_id`, `team_id`, `message_id`, `message` (decoded nRF Cloud message) |

**Renaming a device:** open the admin UI → `devices` → set `name`. The dashboard updates live.

The dashboard only reads public data, so anyone with the URL can watch the demo, but only the
webhook (with the token/secret) can write.

## Customizing

- **Dashboard.** Edit `pocketbase/pb_public/index.html`, then run `scripts/fly-deploy.sh` again.
  You can also open the file from disk and point it at any backend with
  `index.html?pb=https://<app>.fly.dev`.
- **More data** (location, telemetry, …). The full decoded message is already in `raw_messages`.
  Add a collection in a new migration and extract the fields in `nrfcloud.pb.js`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `mrs.sh create` says not reachable | `curl https://<app>.fly.dev/api/health`; `fly logs` |
| Destination stays unverified | `NRFCLOUD_TEAM_ID` set as a Fly secret? `fly logs \| grep PIN` → `mrs.sh verify` |
| Webhook logs `invalid x-api-key` / `invalid signature` | `.env` token/secret differ from the Fly secrets. Run `fly-deploy.sh`, then `mrs.sh create` |
| Dashboard stays on "Connecting…" | Browser console; is `/api/health` reachable from the browser? |
| Messages arrive but no classification | Check `raw_messages` in the admin UI and whether `message.data` holds `classification`. `mrs.sh status` lists delivery errors |
