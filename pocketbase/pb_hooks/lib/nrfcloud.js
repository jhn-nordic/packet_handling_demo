// nRF Cloud message decoding + Neuton AI classification extraction.
//
// Plain CommonJS so it runs in PocketBase's embedded JS engine (goja), which
// has no atob/TextDecoder/npm. Loaded from pb_hooks/nrfcloud.pb.js with
// require(`${__hooks}/lib/nrfcloud.js`).

// ─── Base64 / UTF-8 / CBOR helpers ─────────────────────────────────

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const B64_LOOKUP = {}
for (let i = 0; i < B64.length; i++) B64_LOOKUP[B64[i]] = i
B64_LOOKUP["-"] = 62 // base64url
B64_LOOKUP["_"] = 63

function base64ToBytes(b64) {
  const clean = String(b64).replace(/[\s=]/g, "")
  if (!/^[A-Za-z0-9+/_-]*$/.test(clean)) throw new Error("not base64")
  const out = []
  let buf = 0
  let bits = 0
  for (let i = 0; i < clean.length; i++) {
    buf = (buf << 6) | B64_LOOKUP[clean[i]]
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((buf >> bits) & 0xff)
    }
  }
  return out
}

function utf8Decode(bytes) {
  let s = ""
  for (let i = 0; i < bytes.length; i++) {
    s += "%" + (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16)
  }
  return decodeURIComponent(s) // throws on invalid UTF-8
}

function base64ToText(b64) {
  return utf8Decode(base64ToBytes(b64))
}

// Minimal CBOR decoder (RFC 8949) — enough for nRF Cloud ground-fix bodies:
// ints, byte/text strings, arrays, maps, tags (ignored), floats, simple values.
function cborDecode(bytes) {
  let pos = 0

  function readUint(n) {
    let v = 0
    for (let i = 0; i < n; i++) v = v * 256 + bytes[pos++]
    return v
  }

  function readFloat(n) {
    const view = new DataView(new Uint8Array(bytes.slice(pos, pos + n)).buffer)
    pos += n
    if (n === 4) return view.getFloat32(0)
    if (n === 8) return view.getFloat64(0)
    // half precision
    const h = view.getUint16(0)
    const exp = (h >> 10) & 0x1f
    const frac = h & 0x3ff
    const sign = h & 0x8000 ? -1 : 1
    if (exp === 0) return sign * Math.pow(2, -14) * (frac / 1024)
    if (exp === 31) return frac ? NaN : sign * Infinity
    return sign * Math.pow(2, exp - 15) * (1 + frac / 1024)
  }

  function readLength(info) {
    if (info < 24) return info
    if (info === 24) return readUint(1)
    if (info === 25) return readUint(2)
    if (info === 26) return readUint(4)
    if (info === 27) return readUint(8)
    if (info === 31) return -1 // indefinite
    throw new Error("invalid CBOR length")
  }

  function item() {
    if (pos >= bytes.length) throw new Error("unexpected end of CBOR")
    const ib = bytes[pos++]
    const major = ib >> 5
    const info = ib & 0x1f

    if (major === 7) {
      if (info === 20) return false
      if (info === 21) return true
      if (info === 22 || info === 23) return null
      if (info === 25) return readFloat(2)
      if (info === 26) return readFloat(4)
      if (info === 27) return readFloat(8)
      if (info === 31) return BREAK
      return info < 24 ? info : readUint(1)
    }

    const len = readLength(info)
    switch (major) {
      case 0: return len
      case 1: return -1 - len
      case 2:
      case 3: {
        let chunk
        if (len < 0) {
          chunk = []
          for (let c = item(); c !== BREAK; c = item()) chunk = chunk.concat(major === 2 ? c : [c])
          return major === 2 ? chunk : chunk.join("")
        }
        chunk = bytes.slice(pos, pos + len)
        pos += len
        return major === 2 ? chunk : utf8Decode(chunk)
      }
      case 4: {
        const arr = []
        if (len < 0) for (let v = item(); v !== BREAK; v = item()) arr.push(v)
        else for (let i = 0; i < len; i++) arr.push(item())
        return arr
      }
      case 5: {
        const obj = {}
        if (len < 0) for (let k = item(); k !== BREAK; k = item()) obj[String(k)] = item()
        else for (let i = 0; i < len; i++) { const k = item(); obj[String(k)] = item() }
        return obj
      }
      case 6: return item() // tag: return tagged value
    }
    throw new Error("unsupported CBOR major type " + major)
  }

  const BREAK = {}
  return item()
}

// ─── Message body decoding ─────────────────────────────────────────
// Decodes string data in message.data. Two known formats:
//
//   1. JSON string (appId "DETECTION" d2c messages):
//      { "data": "{\"classification\":\"Idle\",\"probability\":99}" }
//
//   2. Base64-encoded JSON (raw d2c):
//      { "data": "eyJjbGFzc2lmaWNhdGlvbi..." }
//
// CoAP messages use request/response bodies:
//   PATCH /state/reported  →  base64-encoded JSON
//   FETCH /loc/ground-fix  →  base64-encoded CBOR

function decodeMessage(msg) {
  const out = JSON.parse(JSON.stringify(msg))
  const m = out.message || {}

  if (typeof m.data === "string") {
    const raw = m.data
    try {
      m.data = JSON.parse(raw)
      m.encodedData = raw
    } catch (_) {
      try {
        m.data = JSON.parse(base64ToText(raw))
        m.encodedData = raw
      } catch (_) {
        // leave as-is
      }
    }
  }

  if (out.coapRequestUrl === "PATCH /state/reported" && m.request && typeof m.request.body === "string") {
    try {
      const raw = m.request.body
      m.request.body = JSON.parse(base64ToText(raw))
      m.request.encodedBody = raw
    } catch (e) {
      console.error("Failed to decode PATCH body:", e)
    }
  }

  if (out.coapRequestUrl === "FETCH /loc/ground-fix") {
    for (const part of ["request", "response"]) {
      if (m[part] && typeof m[part].body === "string") {
        try {
          const raw = m[part].body
          m[part].body = cborDecode(base64ToBytes(raw))
          m[part].encodedBody = raw
        } catch (e) {
          console.error(`Failed CBOR-decode ${part} body:`, e)
        }
      }
    }
  }

  return out
}

// ─── Neuton AI classification ──────────────────────────────────────

const CLASS_NAMES = ["idle", "carrying", "car", "shaking", "impact", "freefall", "placed"]

// Firmware label → dashboard key. Firmware sends:
//   "Idle", "Shaking", "Impact", "Free Fall", "Carrying", "in Car", "Placed"
const FW_LABEL_MAP = {
  "idle": "idle",
  "shaking": "shaking",
  "impact": "impact",
  "free fall": "freefall",
  "freefall": "freefall",
  "carrying": "carrying",
  "in car": "car",
  "car": "car",
  "placed": "placed",
}

function toClassName(s) {
  return FW_LABEL_MAP[String(s).toLowerCase()] || null
}

// `probability` is an integer percentage (0-100); normalise to 0.0-1.0.
function normaliseConfidence(v) {
  if (typeof v !== "number") return 1.0
  return v > 1 ? v / 100 : v
}

// Optional full distribution, e.g. { "Idle": 2, "Carrying": 92, ... }
function normaliseProbabilities(p) {
  if (!p || typeof p !== "object" || Array.isArray(p)) return null
  const out = {}
  for (const k in p) {
    const cls = toClassName(k)
    if (cls && typeof p[k] === "number") out[cls] = normaliseConfidence(p[k])
  }
  return Object.keys(out).length ? out : null
}

function tryParseClassification(obj) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return null

  // Primary format: { classification, probability }
  if (typeof obj.classification === "string") {
    const state = toClassName(obj.classification)
    if (state) {
      return {
        state,
        confidence: normaliseConfidence(obj.probability),
        probabilities: normaliseProbabilities(obj.probabilities),
      }
    }
  }
  // Fallback: { state, confidence }
  if (typeof obj.state === "string") {
    const state = toClassName(obj.state)
    if (state) {
      return {
        state,
        confidence: normaliseConfidence(obj.confidence),
        probabilities: normaliseProbabilities(obj.probabilities),
      }
    }
  }
  return null
}

function extractClassification(decoded) {
  const m = (decoded && decoded.message) || {}

  // Raw d2c: decoded message.data
  if (m.data != null) {
    const r = tryParseClassification(m.data)
    if (r) return r
  }

  // PATCH /state/reported (decoded request body)
  const body = m.request && m.request.body
  if (body && typeof body === "object") {
    const reported = body.reported || {}
    const candidates = [reported.neuton, reported.classify, body.neuton, body.classify, body]
    for (const c of candidates) {
      const r = tryParseClassification(c)
      if (r) return r
    }
  }

  return null
}

module.exports = {
  base64ToBytes,
  base64ToText,
  cborDecode,
  decodeMessage,
  extractClassification,
  CLASS_NAMES,
}
