/// <reference path="../pb_data/types.d.ts" />

// nRF Cloud Message Routing Service (MRS) webhook
//
//   POST /api/nrfcloud/webhook
//
// 1. Answers the MRS destination verification request (echoes the team ID
//    header so the destination is verified automatically).
// 2. Authenticates deliveries with the destination token (x-api-key) and/or
//    secret (x-nrfcloud-signature = HMAC-SHA256 of the raw body).
// 3. Decodes each message, stores it in `raw_messages`, upserts `devices`
//    and inserts Neuton AI results into `classifications`, which the
//    dashboard (pb_public/index.html) receives via PocketBase realtime.
//
// Environment (set with `fly secrets set` or in .env for docker compose):
//   NRFCLOUD_WEBHOOK_TOKEN   token configured on the MRS destination
//   NRFCLOUD_WEBHOOK_SECRET  secret configured on the MRS destination
//   NRFCLOUD_TEAM_ID         your nRF Cloud team ID (for auto-verification)
//   RAW_RETENTION_DAYS       prune raw_messages older than this (default 7, 0 = keep)
//
// Hook handlers run in isolated JS contexts, so everything they use must be
// required/read inside the handler.

routerAdd("POST", "/api/nrfcloud/webhook", (e) => {
  const lib = require(`${__hooks}/lib/nrfcloud.js`)

  const token = $os.getenv("NRFCLOUD_WEBHOOK_TOKEN")
  const secret = $os.getenv("NRFCLOUD_WEBHOOK_SECRET")
  const teamId = $os.getenv("NRFCLOUD_TEAM_ID") || e.request.header.get("x-nrfcloud-team-id")

  // Echo the team ID on every response — MRS uses it to auto-verify the destination.
  if (teamId) e.response.header().set("x-nrfcloud-team-id", teamId)

  const rawBody = toString(e.request.body)

  let body
  try {
    body = JSON.parse(rawBody)
  } catch (_) {
    return e.json(400, { error: "invalid json" })
  }

  // ── Destination verification ──
  // Answered before authentication: it only echoes the team ID and logs the PIN.
  if (body.type === "system.verification") {
    const pin = body.messages && body.messages[0] && body.messages[0].verificationToken
    console.log(`nrfcloud: verification request received (PIN ${pin}). ` +
      (teamId ? "Team ID echoed, should auto-verify." : "Set NRFCLOUD_TEAM_ID or verify with: scripts/mrs.sh verify <PIN>"))
    return e.json(200, { ok: true })
  }

  // ── Authentication ──
  if (token && !$security.equal(e.request.header.get("x-api-key"), token)) {
    console.warn("nrfcloud: rejected request with invalid x-api-key")
    return e.json(401, { error: "invalid api key" })
  }
  if (secret) {
    const signature = (e.request.header.get("x-nrfcloud-signature") || "").toLowerCase()
    if (!$security.equal(signature, $security.hs256(rawBody, secret))) {
      console.warn("nrfcloud: rejected request with invalid x-nrfcloud-signature")
      return e.json(401, { error: "invalid signature" })
    }
  }

  const messages = Array.isArray(body.messages) ? body.messages : []
  const rawCol = $app.findCollectionByNameOrId("raw_messages")
  const devCol = $app.findCollectionByNameOrId("devices")
  const clsCol = $app.findCollectionByNameOrId("classifications")

  let stored = 0, duplicates = 0, classified = 0, errors = 0

  for (const msg of messages) {
    try {
      // MRS retries failed deliveries for 24h — skip messages we already have.
      if (msg.messageId) {
        try {
          $app.findFirstRecordByData("raw_messages", "message_id", msg.messageId)
          duplicates++
          continue
        } catch (_) { /* not found → new message */ }
      }

      const decoded = lib.decodeMessage(msg)
      const deviceId = decoded.deviceId || ""

      $app.runInTransaction((txApp) => {
        const raw = new Record(rawCol)
        raw.set("device_id", deviceId)
        raw.set("team_id", decoded.teamId || "")
        raw.set("message_id", decoded.messageId || "")
        raw.set("message", decoded)
        txApp.save(raw)

        if (deviceId) {
          let dev
          try {
            dev = txApp.findFirstRecordByData("devices", "device_id", deviceId)
          } catch (_) {
            dev = new Record(devCol)
            dev.set("device_id", deviceId)
          }
          dev.set("last_seen", new DateTime())
          txApp.save(dev)
        }

        const c = lib.extractClassification(decoded)
        if (c) {
          const rec = new Record(clsCol)
          rec.set("device_id", deviceId)
          rec.set("state", c.state)
          rec.set("confidence", c.confidence)
          if (c.probabilities) rec.set("probabilities", c.probabilities)
          txApp.save(rec)
          classified++
          console.log(`nrfcloud: ${deviceId} → ${c.state} (${(c.confidence * 100).toFixed(1)}%)`)
        }
      })
      stored++
    } catch (err) {
      errors++
      console.error(`nrfcloud: failed to store message from ${msg && msg.deviceId}:`, err)
    }
  }

  // A 5xx makes MRS retry the whole batch; only do that if nothing was stored.
  const status = errors > 0 && stored === 0 && duplicates === 0 ? 500 : 200
  return e.json(status, { stored, duplicates, classified, errors })
})

// Daily cleanup of raw_messages (classifications and devices are kept).
cronAdd("prune_raw_messages", "15 3 * * *", () => {
  const days = parseInt($os.getenv("RAW_RETENTION_DAYS") || "7", 10)
  if (!days || days <= 0) return
  const cutoff = new DateTime().addDate(0, 0, -days).string()
  $app.db()
    .newQuery("DELETE FROM raw_messages WHERE created < {:cutoff}")
    .bind({ cutoff })
    .execute()
  console.log(`nrfcloud: pruned raw_messages older than ${days} days`)
})
