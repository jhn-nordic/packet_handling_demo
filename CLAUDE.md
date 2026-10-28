# CLAUDE.md

PocketBase + Docker version of the SmartParcel demo (original Supabase version: `../ai_edge_demo`).
Meant for partners to replicate on their own nRF Cloud team and Fly.io account. See README.md.

## Layout

- `pocketbase/pb_hooks/nrfcloud.pb.js`: MRS webhook route + raw_messages prune cron. Runs in
  PocketBase's goja JSVM: no npm, no atob/TextDecoder. Each handler runs in an isolated context,
  so `require()` helpers inside the handler.
- `pocketbase/pb_hooks/lib/nrfcloud.js`: pure CommonJS decode/classify logic. It also runs under
  Node, so test it with `node -e 'require("./pocketbase/pb_hooks/lib/nrfcloud.js")…'`.
- `pocketbase/pb_migrations/`: collection schema. Add new migrations; don't edit applied ones.
- `pocketbase/pb_public/index.html`: dashboard, a single self-contained file (PocketBase JS SDK from CDN).
- `scripts/`: bash that must work with macOS bash 3.2 under `set -u`. Use
  `${arr[@]+"${arr[@]}"}` for possibly-empty arrays and never `${x:+--flag "$x"}`.

## Pinned versions

PocketBase 0.40.5 (`Dockerfile` `PB_VERSION`), PocketBase JS SDK 0.28.1 (`index.html` `PB_SDK`).

## Local test loop

```sh
docker compose up --build
ENV_FILE=/dev/null NRFCLOUD_WEBHOOK_TOKEN= NRFCLOUD_WEBHOOK_SECRET= scripts/send-test.sh --demo
```
