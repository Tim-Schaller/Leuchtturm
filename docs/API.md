# Server API v1

All bodies are JSON. Binary fields are **unpadded base64url** strings. IDs (device, circle, invite) are 16 random bytes in base64url (22 characters). Errors look like:

```json
{"error": "not_found", "message": "not found"}
```

| Status | `error` | Meaning |
|--------|---------|---------|
| 400 | `bad_request` | Invalid JSON, sizes or parameters |
| 401 | `unauthorized` | Missing or invalid signature, or replay |
| 401 | `stale_timestamp` | Clock skew > 2 min; body includes `server_time` |
| 401 | `unknown_device` | Signature valid, device not registered |
| 403 | `forbidden` | Not allowed (e.g. member acting as owner) |
| 404 | `not_found` | Unknown, or caller is not a member (indistinguishable) |
| 404 | `invalid_invite` | Invite unknown, expired, used up or wrong token |
| 409 | `conflict` | ID taken, wrong epoch, already a member |
| 413 | `too_large` | Body > 64 KiB |
| 429 | `limit_reached` | Member or invite limit |
| 503 | `busy` / `unavailable` | Replay cache full / database down |

## Authentication

Every request except `/healthz` and `/v1/info` carries:

```
Authorization: LT1 key=<ed25519 pubkey>,ts=<unix seconds>,nonce=<16 random bytes>,sig=<signature>
```

The Ed25519 signature covers the UTF-8 string

```
LT1\n<METHOD>\n<request URI incl. query>\n<ts>\n<nonce as sent>\n<lowercase hex SHA-256 of the body>
```

The server rejects timestamps more than 2 minutes off and any `(key, nonce)` pair seen within 4 minutes. Clients that get `stale_timestamp` adjust their clock offset from `server_time` and retry once. A reference vector is in [test-vectors/auth-v1.json](test-vectors/auth-v1.json); both the Go and Swift test suites verify it.

## Endpoints

### Public

| Method | Path | Response |
|--------|------|----------|
| GET | `/healthz` | `{"status":"ok"}` |
| GET | `/v1/info` | `{"name","api","auth","license","source","time"}` |

### Devices

**`POST /v1/devices`**: register (idempotent). `signing_key` must be the key that signed the request.

```json
{"signing_key": "…32 bytes…", "agreement_key": "…32 bytes…"}
→ 201 (new) or 200 (known): {"device_id": "…"}
```

**`DELETE /v1/devices/me`** → 204. Leaves all circles (ownership passes on, empty circles are deleted) and deletes the device.

### Circles

**`POST /v1/circles`**

```json
{"circle_id": "…client-chosen…", "meta_blob": "…", "member_blob": "…", "wrapped_key": "…"}
→ 201 {"circle_id": "…", "epoch": 1}
```

**`GET /v1/circles`** → `{"circles": [{"circle_id","epoch","role","meta_blob","wrapped_key"|null}]}`

**`GET /v1/circles/{id}`** (members only)

```json
{"circle_id": "…", "epoch": 2, "meta_blob": "…", "my_wrapped_key": "…"|null,
 "members": [{"device_id","signing_key","agreement_key","role","member_blob","joined_at"}]}
```

Members are ordered by join time. `my_wrapped_key` is null for members who joined via invite and have not seen a rotation yet (they got the key from the invite).

**`PUT /v1/circles/{id}/members/me`** `{"member_blob": "…"}` → 204

**`PUT /v1/circles/{id}/meta`** `{"meta_blob": "…"}` → 204 (owner only)

**`POST /v1/circles/{id}/leave`** → 204

**`POST /v1/circles/{id}/members/{device}/remove`** (owner only): removes a member and rotates the key atomically.

```json
{"epoch": 3, "meta_blob": "…under new key…",
 "wrapped_keys": [{"device_id": "…", "wrapped_key": "…"}]}
→ 200 {"epoch": 3}
```

`epoch` must be current + 1 (else 409); `wrapped_keys` must cover exactly the remaining members (else 400). All open invites of the circle are revoked.

### Invites

**`POST /v1/circles/{id}/invites`** (members)

```json
{"epoch": 1, "auth_token_hash": "…32 bytes…", "sealed_circle_key": "…",
 "expires_in_seconds": 86400, "max_uses": 1}
→ 201 {"invite_id": "…", "expires_at": 1800086400}
```

`expires_in_seconds`: 60 to 604800 (default 86400). `max_uses`: 1 to 50 (default 1). `epoch` must be current (else 409).

**`DELETE /v1/circles/{id}/invites/{invite}`** → 204 (creator or owner)

**`POST /v1/invites/{invite}/redeem`**

```json
{"auth_token": "…32 bytes…", "member_blob": "AA"}
→ 200 {"circle_id": "…", "epoch": 1, "role": "member", "sealed_circle_key": "…"}
```

The joiner usually sends the placeholder card `0x00` (`"AA"`) and uploads the real card after decrypting the circle key.

## Field limits

| Field | Max decoded size |
|-------|------------------|
| `meta_blob`, `member_blob` | 2048 bytes |
| `wrapped_key`, `sealed_circle_key` | 512 bytes |
| `wrapped_keys` entries | 1000 |
