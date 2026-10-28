/// <reference path="../pb_data/types.d.ts" />

// SmartParcel collections
//
//   devices          one row per nRF Cloud device that has sent data (public read)
//   raw_messages     every decoded nRF Cloud message, for debugging (superuser only)
//   classifications  Neuton AI results consumed by the dashboard (public read + realtime)
//
// Records are written only by pb_hooks/nrfcloud.pb.js, which bypasses API rules,
// so createRule/updateRule/deleteRule stay null (superusers only).

migrate((app) => {
  const devices = new Collection({
    type: "base",
    name: "devices",
    listRule: "",
    viewRule: "",
    fields: [
      { type: "text", name: "device_id", required: true, max: 128 },
      // Optional friendly name shown in the dashboard filter (edit in the admin UI)
      { type: "text", name: "name", max: 128 },
      { type: "date", name: "last_seen" },
      { type: "autodate", name: "created", onCreate: true },
      { type: "autodate", name: "updated", onCreate: true, onUpdate: true },
    ],
    indexes: ["CREATE UNIQUE INDEX idx_devices_device_id ON devices (device_id)"],
  })
  app.save(devices)

  const raw = new Collection({
    type: "base",
    name: "raw_messages",
    fields: [
      { type: "text", name: "device_id", max: 128 },
      { type: "text", name: "team_id", max: 128 },
      { type: "text", name: "message_id", max: 128 },
      { type: "json", name: "message", maxSize: 1048576 },
      { type: "autodate", name: "created", onCreate: true },
    ],
    indexes: [
      "CREATE INDEX idx_raw_messages_message_id ON raw_messages (message_id)",
      "CREATE INDEX idx_raw_messages_created ON raw_messages (created)",
    ],
  })
  app.save(raw)

  const classifications = new Collection({
    type: "base",
    name: "classifications",
    listRule: "",
    viewRule: "",
    fields: [
      { type: "text", name: "device_id", max: 128 },
      {
        type: "select",
        name: "state",
        required: true,
        maxSelect: 1,
        values: ["idle", "carrying", "car", "shaking", "impact", "freefall", "placed"],
      },
      { type: "number", name: "confidence", min: 0, max: 1 },
      { type: "json", name: "probabilities" },
      { type: "autodate", name: "created", onCreate: true },
    ],
    indexes: [
      "CREATE INDEX idx_classifications_device_created ON classifications (device_id, created)",
    ],
  })
  app.save(classifications)
}, (app) => {
  for (const name of ["classifications", "raw_messages", "devices"]) {
    app.delete(app.findCollectionByNameOrId(name))
  }
})
