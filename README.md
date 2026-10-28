# Nordic SmartParcel — PocketBase edition

A self-hostable version of the SmartParcel package-handling demo. A Thingy:91 X classifies how a
parcel is handled (idle, carrying, in car, shaking, impact, free fall, placed) with an on-device
Neuton AI model. nRF Cloud forwards each result through the **Message Routing Service (MRS)** to
a [PocketBase](https://pocketbase.io) backend on Fly.io, and a live dashboard shows it in real time.

```
Thingy:91 X ── LTE-M/NB-IoT ──► nRF Cloud ── MRS webhook (HTTPS) ──► PocketBase on Fly.io
                                                                     │  verify → decode → store
                                                                     ▼
                                           browser ◄── realtime ── dashboard (served at /)
```

This guide takes you from an nRF Cloud organization and a Thingy:91 X to parcel movements on a
live dashboard in seven steps:

1. [Check what you need](#step-1-check-what-you-need)
2. [Configure the project](#step-2-configure-the-project)
3. [Deploy the backend to Fly.io](#step-3-deploy-the-backend-to-flyio)
4. [Route nRF Cloud messages to the backend](#step-4-route-nrf-cloud-messages-to-the-backend)
5. [Flash the Thingy:91 X](#step-5-flash-the-thingy91-x)
6. [Claim the device in nRF Cloud](#step-6-claim-the-device-in-nrf-cloud)
7. [Verify](#step-7-verify)

No device at hand? Do steps 1–4 and use `scripts/send-test.sh --demo` instead of steps 5–6.

## Step 1: Check what you need

1. Make sure you have the following before you start, so you don't get stuck halfway:

    - An [nRF Cloud](https://nrfcloud.com) organization where you are **Organization Admin**.
      Managing Message Routing requires that role. A Developer plan includes one destination.
    - A [Fly.io](https://fly.io) account. The backend runs on one small always-on machine, which
      costs a few US dollars per month; see [Fly pricing](https://fly.io/docs/about/pricing/).
    - A Nordic Thingy:91 X, plus an external debug probe that supports Arm Cortex-M33 (for
      example an nRF9151 DK) and a 10-pin 1.27 mm SWD cable.
    - A serial terminal, such as the **Serial Terminal** app in
      [nRF Connect for Desktop](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-Desktop).

1. Install the command-line tools:

    - `git`, `curl`, `jq` and `openssl`
    - [`flyctl`](https://fly.io/docs/flyctl/install/)
    - [nRF Util](https://docs.nordicsemi.com/bundle/nrfutil/page/guides/installing.html) with the
      `device` command: run `nrfutil install device` after installing nRF Util. The
      **Programmer** app in nRF Connect for Desktop works too.
    - Optional, to run the backend locally: `docker`

1. Clone the repository:

    ```sh
    git clone https://github.com/jhn-nordic/packet_handling_demo.git
    cd packet_handling_demo
    ```

**Checkpoint:** `fly version`, `nrfutil device --version` and `jq --version` all print a version.

## Step 2: Configure the project

All settings live in `.env`, which is git-ignored. The scripts and `docker compose` read it.

1. Create the file:

    ```sh
    cp .env.example .env
    ```

1. Create an **Organization Auth Token** (OAT) in nRF Cloud under
   **Admin → Organization Auth Tokens → Create Token**. Copy it right away, because it's shown
   only once. Set it as `NRFCLOUD_ORG_TOKEN`.

1. Open your organization's **default project** in nRF Cloud and read the slugs from the browser
   URL, `…/organizations/<ORG>/projects/<PROJECT>/…`. Set them as `NRFCLOUD_ORG` and
   `NRFCLOUD_PROJECT`. Destinations are organization-wide and managed from the default project.

1. Set the remaining values:

    | Variable | Value |
    |---|---|
    | `FLY_APP` | A globally unique app name. The dashboard becomes `https://<FLY_APP>.fly.dev` |
    | `FLY_REGION` | A [Fly region](https://fly.io/docs/reference/regions/) close to you, for example `arn` (Stockholm) or `iad` (Virginia) |
    | `PB_ADMIN_EMAIL`, `PB_ADMIN_PASSWORD` | Login for the PocketBase admin UI |

    Leave `NRFCLOUD_WEBHOOK_TOKEN` and `NRFCLOUD_WEBHOOK_SECRET` empty. The scripts generate
    them in the next step.

**Checkpoint:** `.env` has values for `NRFCLOUD_ORG_TOKEN`, `NRFCLOUD_ORG`, `NRFCLOUD_PROJECT`,
`FLY_APP`, `PB_ADMIN_EMAIL` and `PB_ADMIN_PASSWORD`.

## Step 3: Deploy the backend to Fly.io

1. Log in to Fly:

    ```sh
    fly auth login
    ```

1. Deploy:

    ```sh
    scripts/fly-deploy.sh
    ```

    The script generates the webhook token and secret into `.env`, creates the Fly app and a
    1 GB volume for the database, sets the secrets, and deploys a single machine. It's safe to
    run again, for example after you change the dashboard.

1. Check that the backend answers:

    ```sh
    curl https://<FLY_APP>.fly.dev/api/health
    ```

1. Send one fake classification through the full backend path:

    ```sh
    scripts/send-test.sh Carrying 92
    ```

**Checkpoint:** The health check returns `{"message":"API is healthy.","code":200,"data":{}}`.
`send-test.sh` prints `{"stored":1,…,"classified":1,…} [200]`. With
`https://<FLY_APP>.fly.dev/` open in a browser, the header pill shows **Live — Thingy:91 X** and
the dashboard switches to **CARRYING** when you send the test message.

## Step 4: Route nRF Cloud messages to the backend

1. Create the Message Routing destination:

    ```sh
    scripts/mrs.sh create
    ```

    This creates a destination named `smartparcel-<FLY_APP>` that posts to
    `https://<FLY_APP>.fly.dev/api/nrfcloud/webhook`, protected by the webhook token and secret.
    nRF Cloud then sends a verification request, and the backend answers it automatically. The
    destination only receives device messages and shadow updates. See
    [Message Routing details](#message-routing-details) to change that.

**Checkpoint:** The script prints the following, followed by the destination with
`"verified": true`:

```text
Creating destination 'smartparcel-<FLY_APP>' → https://<FLY_APP>.fly.dev/api/nrfcloud/webhook
Waiting for verification ✓ verified
```

If it stops with `Destination not verified automatically`, find the PIN with
`fly logs --app <FLY_APP> | grep PIN` and run `scripts/mrs.sh verify <PIN>`.

## Step 5: Flash the Thingy:91 X

`firmware/parcel_tracker.hex` is a merged image (bootloaders, TF-M, application) for the
nRF9151, built on the [Asset Tracker Template](https://docs.nordicsemi.com/bundle/asset-tracker-template-latest/page/index.html).
A merged image is flashed with an external debug probe, not over the Thingy's USB port.

1. Prepare the hardware:

    1. Remove the rubber cover and connect the SWD cable from the probe to **P8** on the Thingy:91 X.
    1. Connect the probe to your computer, and power the Thingy:91 X over USB-C.
    1. Switch the Thingy:91 X on (**SW1** to **ON**) and set **SW2** to **nRF91**.

1. Find the probe's serial number:

    ```sh
    nrfutil device list
    ```

1. Erase the nRF9151 and flash the firmware:

    ```sh
    nrfutil device program --firmware firmware/parcel_tracker.hex \
      --serial-number <JLINK_SERIAL> --traits jlink --x-family nrf91 \
      --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ,reset=RESET_SYSTEM
    ```

    For the Programmer app, recovery from a protected device and more detail, see
    [firmware/README.md](firmware/README.md).

1. Disconnect the probe and open a serial terminal on the Thingy:91 X's USB serial port.

**Checkpoint:** After a reset, the log shows `*** Booting nRF Connect SDK v3.2.99-… ***`, and
pressing Enter gives a `uart:~$` prompt.

## Step 6: Claim the device in nRF Cloud

A Thingy:91 X can only send data after it's claimed (onboarded) to an nRF Cloud organization.
It must be the **same organization as your Message Routing destination**. Until then, the log
shows `Provisioning failed, device not claimed`. If the device is already listed under
**Fleet → Devices** in your organization, skip to step 7.

1. In the serial terminal, read the device's attestation token:

    ```text
    uart:~$ at at%attesttoken
    ```

    Copy the value inside the quotes after `%ATTESTTOKEN:`. It's two parts separated by a `.`;
    copy both.

1. In nRF Cloud, open your organization and go to **Fleet → Devices → Add devices**.
1. Select **nRF91 Series**, paste the token into **Attestation token**, then preview and confirm.
1. Back in the serial terminal, fetch the device's credentials right away:

    ```text
    uart:~$ att_cloud provision
    ```

    Provisioning takes up to a minute. LTE disconnecting and reconnecting during it is normal.

**Checkpoint:** The log shows `Cloud connected - sending DETECTION_START command`, and the device
appears as connected under **Fleet → Devices**.

## Step 7: Verify

1. Open `https://<FLY_APP>.fly.dev/`.
1. Pick up the parcel and walk with it, put it down, or shake it.
1. Watch the backend receive the results:

    ```sh
    fly logs --app <FLY_APP> | grep nrfcloud
    ```

**Checkpoint:** Within seconds of each movement, the dashboard's large state label changes (for
example to **CARRYING**) and a new entry appears in the journey timeline. `fly logs` shows lines
like `nrfcloud: <device-id> → carrying (92.0%)`.

When a second device reports, a **Device** selector appears in the dashboard header. Choosing a
device shows only that device, and the choice is kept in the URL (`/?device=<device-id>`), so you
can bookmark one screen per parcel.

If nothing shows up, see [Troubleshooting](#troubleshooting).

## Next steps

| I want to | Read |
|---|---|
| Demo without a device | Run `scripts/send-test.sh --demo`, which plays a journey from two fake parcels |
| Give devices friendly names | [Data model](#data-model) |
| Run the backend on my laptop | [Run locally with Docker](#run-locally-with-docker) |
| Check, test or remove the destination | [Message Routing details](#message-routing-details) |
| Change the dashboard or store more data | [Customizing](#customizing) |
| Flash with the Programmer app, or re-claim a device | [firmware/README.md](firmware/README.md) |

---

## Reference

### What's in the repository

| Path | What it does |
|---|---|
| `pocketbase/pb_hooks/nrfcloud.pb.js` | `POST /api/nrfcloud/webhook`: MRS verification, token and HMAC signature check, dedupe, stores messages, extracts classifications |
| `pocketbase/pb_hooks/lib/nrfcloud.js` | base64 / CBOR decoding and firmware-label → state mapping |
| `pocketbase/pb_migrations/` | Creates the `devices`, `raw_messages` and `classifications` collections |
| `pocketbase/pb_public/index.html` | The dashboard (single HTML file, served at `/`) |
| `Dockerfile`, `docker-compose.yml` | Container image and local run |
| `fly.toml`, `scripts/fly-deploy.sh` | Fly.io deployment |
| `scripts/mrs.sh` | Create, verify, test and delete the Message Routing destination |
| `scripts/send-test.sh` | Sends fake signed nRF Cloud deliveries, so you can demo without a device |
| `firmware/parcel_tracker.hex` | Thingy:91 X (nRF9151) firmware. See [firmware/README.md](firmware/README.md) |

Compared with the original Supabase version: there's no device whitelist (every device in the
organization that MRS routes here is accepted), the dashboard has the device filter, and one
service replaces the two edge functions and the database webhook. Raw messages are pruned after
`RAW_RETENTION_DAYS` (default 7).

### Message Routing details

```sh
scripts/mrs.sh status          # verified? recent delivery errors?
scripts/mrs.sh list            # all destinations in the organization
scripts/mrs.sh test            # nRF Cloud sends a test message
scripts/mrs.sh resend          # new verification PIN …
scripts/mrs.sh verify 123456   # … and confirm it
scripts/mrs.sh delete
```

- **Finding the destination.** Destinations are found by name: `MRS_DESTINATION_NAME`, default
  `smartparcel-<FLY_APP>`. Running `create` again updates the URL, token and secret instead of
  creating a duplicate.
- **API and authentication.** The scripts use the organization/project scoped nRF Cloud API with
  the OAT as a Bearer token: `GET/POST /v1/organizations/{ORG}/projects/{PROJECT}/destinations`,
  `PATCH/DELETE …/destinations/{ID}`, `POST …/{ID}/test`, `POST …/{ID}/verification` and
  `PATCH …/{ID}/verification/confirm`.
- **Verification.** The webhook echoes back the `x-nrfcloud-team-id` header it receives, so
  verification is automatic. As a fallback it logs the PIN.
- **Delivery authentication.** Each delivery carries the token in `x-api-key` and an HMAC-SHA256
  of the raw body in `x-nrfcloud-signature`. The webhook checks both.
- **Filtering.** By default only the `device_messages` and `shadow` categories are routed, so you
  aren't billed for location or FOTA traffic the demo ignores. Change this with
  `MRS_CATEGORIES=location,device_messages scripts/mrs.sh create`, or route everything with
  `MRS_CATEGORIES=`.
- Docs: <https://docs.nrfcloud.com/docs/nrfcloud/message-routing>

### Run locally with Docker

```sh
docker compose up --build     # → http://localhost:8090  (admin: http://localhost:8090/_/)
scripts/send-test.sh --demo   # in another terminal
```

To receive real device data locally, expose the container through an HTTPS tunnel and point the
destination at it:

```sh
cloudflared tunnel --url http://localhost:8090     # or: ngrok http 8090
scripts/mrs.sh create https://<random>.trycloudflare.com
```

Set the webhook token and secret in `.env` before `docker compose up`, so the container and the
destination share the same credentials.

### Message format

The firmware sends a device message with `appId: "DETECTION"`:

```json
{ "appId": "DETECTION", "messageType": "DATA", "data": "{\"classification\":\"Carrying\",\"probability\":92}" }
```

The webhook also accepts `data` as base64-encoded JSON, as an object, or in a shadow update
(`PATCH /state/reported` with `reported.neuton` / `reported.classify`). Firmware labels map to
these states:

| Firmware label | State | Severity |
|---|---|---|
| `Idle`, `Carrying`, `in Car`, `Placed` | `idle`, `carrying`, `car`, `placed` | OK |
| `Shaking` | `shaking` | Warning (quality −4) |
| `Impact`, `Free Fall` | `impact`, `freefall` | Alert (quality −12 / −10) |

`probability` is a percentage from 0 to 100. To get full probability bars, add an optional
`probabilities` map such as `{"Idle": 2, "Carrying": 92, …}`.

### Data model

The PocketBase admin UI is at `https://<FLY_APP>.fly.dev/_/`.

| Collection | Access | Fields |
|---|---|---|
| `devices` | public read | `device_id`, `name` (optional friendly name shown in the filter), `last_seen` |
| `classifications` | public read + realtime | `device_id`, `state`, `confidence` (0–1), `probabilities` |
| `raw_messages` | admin only | `device_id`, `team_id`, `message_id`, `message` (decoded nRF Cloud message) |

To rename a device, open the admin UI → `devices` and set `name`. The dashboard updates live.

The dashboard only reads public data, so anyone with the URL can watch the demo. Only the webhook,
with the token and secret, can write.

### Customizing

- **Dashboard.** Edit `pocketbase/pb_public/index.html`, then run `scripts/fly-deploy.sh` again.
  You can also open the file from disk and point it at any backend with
  `index.html?pb=https://<FLY_APP>.fly.dev`.
- **More data** (location, telemetry, …). The full decoded message is already in `raw_messages`.
  Add a collection in a new migration and extract the fields in `nrfcloud.pb.js`.

### Troubleshooting

| Symptom | Check |
|---|---|
| `mrs.sh create` says not reachable | `curl https://<FLY_APP>.fly.dev/api/health`; `fly logs` |
| `mrs.sh` gets HTTP 401 | The OAT is wrong or was deleted. Create a new one under Admin → Organization Auth Tokens |
| `mrs.sh` gets HTTP 403 | Managing destinations needs Organization Admin rights in `NRFCLOUD_ORG` |
| `mrs.sh` gets HTTP 404 | `NRFCLOUD_ORG` / `NRFCLOUD_PROJECT` don't match the URL slugs, or the project isn't the organization's default project |
| Destination stays unverified | `fly logs \| grep PIN` → `mrs.sh verify <PIN>` |
| Webhook logs `invalid x-api-key` / `invalid signature` | `.env` token/secret differ from the Fly secrets. Run `fly-deploy.sh`, then `mrs.sh create` |
| Dashboard stays on "Connecting…" | Browser console; is `/api/health` reachable from the browser? |
| Device log says `Provisioning failed, device not claimed` | Claim it: [Step 6](#step-6-claim-the-device-in-nrf-cloud) |
| Device is connected but nothing reaches the webhook | The device is in a different nRF Cloud organization than the destination. Check **Fleet → Devices** in `NRFCLOUD_ORG` |
| Messages arrive but no classification | Check `raw_messages` in the admin UI and whether `message.data` holds `classification`. `mrs.sh status` lists delivery errors |
