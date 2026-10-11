# Architecture

Status: v1 protocol for identity, circles and invites is implemented (milestone M1). Location sharing (M2+) is still a design. Nothing here has been independently security-reviewed.

## Components

```
┌──────────────────────┐   HTTPS (TLS)        ┌──────────────────────┐
│ iOS app (SwiftUI)    │ ───────────────────► │ leuchtturmd (Go)     │
│  └ LeuchtturmCore    │ ◄─────────────────── │ SQLite (pure Go)     │
│    CryptoKit, API    │   WebSocket (M2)     │ Hetzner, Germany     │
└──────────┬───────────┘                      └──────────┬───────────┘
           │                                             │ APNs (opaque payload, M3)
           └───────────────── Apple Push ◄───────────────┘
```

- **iOS app** (`ios/Leuchtturm`): SwiftUI, iOS 26+, Liquid Glass. Only UI and app state.
- **LeuchtturmCore** (`ios/LeuchtturmCore`): Swift package with all cryptography, wire formats, the API client and the high-level `LeuchtturmClient`. Uses CryptoKit on Apple platforms and swift-crypto on Linux, so the same code is tested on both (including end-to-end against a real server in CI).
- **Server** (`server/`, `leuchtturmd`): single Go binary, SQLite in WAL mode, no separate database service. About 11 MB, runs on the smallest Hetzner instance.

## Identity

- On first launch each device generates two Curve25519 key pairs: **Ed25519** for signing requests and **X25519** for receiving circle keys.
- Private keys live in the **Keychain** with `AfterFirstUnlockThisDeviceOnly` (readable in the background after the first unlock, never synced to iCloud, not included in backups that restore to other devices). They are **not** in the Secure Enclave: the Secure Enclave only supports P-256, and the protocol uses Curve25519 throughout.
- **Device ID** = first 16 bytes of SHA-256(Ed25519 public key), base64url. Clients check that every device ID they see matches its key, so the server cannot relabel keys.
- **No accounts, passwords or tokens.** Every request is signed with the device key (see [API.md](API.md#authentication)). Sign in with Apple is deferred until multi-device support needs an account anchor (see ROADMAP).
- **Safety code**: 12 hex digits derived from a device's two public keys. Comparing it in person proves no key was swapped by the server.

## Circles

- A circle has a random 256-bit **circle key** and an **epoch** (key version, starting at 1).
- The **circle ID** (16 random bytes) is chosen by the creating client, because ciphertexts are bound to it before the circle exists on the server.
- Server-side data per circle: epoch, encrypted **metadata** (name), and per member: role (`owner`/`member`), encrypted **member card** (display name) and optionally a **wrapped circle key**.

### Key wrapping

The circle key is wrapped per member with **HPKE in auth mode** (RFC 9180; DHKEM X25519, HKDF-SHA256, ChaCha20-Poly1305). Auth mode proves to the recipient which member wrapped the key.

```
wrapped = 0x01 | sender device id (16) | HPKE enc (32) | ciphertext (32 + 16)
info    = ctx("leuchtturm/v1/circle-key", circleID, epoch, recipientDeviceID)
aad     = ctx("leuchtturm/v1/circle-key-sender", senderDeviceID)
```

`ctx(label, parts...)` is the label's UTF-8 bytes followed by each part as a 2-byte big-endian length and its UTF-8 bytes. Recipients accept a wrapped key only from a current circle member.

### Encrypted content (metadata, member cards)

```
blob = 0x01 | epoch (u64 BE) | ChaCha20-Poly1305 combined (nonce 12 | ciphertext | tag 16)
aad  = ctx("leuchtturm/v1/member-card", circleID, deviceID) | header   (member cards)
       ctx("leuchtturm/v1/circle-meta", circleID) | header             (metadata)
plaintext = u16 BE length | JSON | zero padding to a multiple of 64 bytes
```

The epoch is readable without a key so clients know which key to use. Padding hides name lengths: all blobs in the M1 tests are exactly 101 bytes. A member card of `0x00` means "no card yet" (used while joining).

### Invites

1. The inviter creates a random 32-byte **secret** and derives two keys with HKDF-SHA256 (no salt): `auth token` (info `leuchtturm/v1/invite/auth`) and `enc key` (info `leuchtturm/v1/invite/enc`).
2. The inviter uploads SHA-256(auth token) and the **sealed circle key**: ChaCha20-Poly1305 under `enc key` over `0x01 | epoch | circle key`, with AAD `ctx("leuchtturm/v1/invite", circleID)`. The invite is pinned to the current epoch.
3. The link `leuchtturm://join?v=1&server=…&id=<invite id>&k=<secret>` is shared privately (QR code or message).
4. The joiner redeems with the auth token. Only then does the server return the sealed key, so **everyone who obtains the circle key appears in the member list**. The joiner then uploads its member card.

The server never sees the secret or the enc key. Invites expire (1 minute to 7 days), have a use limit (1 to 50) and are all revoked when the key rotates.

### Removing members and key rotation

The owner removes a member in one atomic request that contains: the new epoch (current + 1), the circle metadata re-encrypted under a fresh key, and the fresh key wrapped for **exactly** every remaining member. The server rejects incomplete rotations. Remaining members unwrap the new key on their next sync and re-encrypt their own member card under it. The removed device keeps old keys but receives nothing new.

If the owner leaves, the longest-standing member becomes owner. Empty circles are deleted.

## Data in transit and at rest

| Data | Encrypted client-side | Visible to server | Status |
|------|-----------------------|-------------------|--------|
| Circle name | yes | ciphertext, padded size, epoch | M1 |
| Display names | yes | ciphertext, padded size, epoch | M1 |
| Circle membership, roles | no | which devices are in which circle | M1 |
| Device public keys | no | public keys | M1 |
| Live location | yes (circle key) | ciphertext, size, time | M2 |
| Places / geofences | yes | ciphertext only, evaluated on device | M3 |
| Location history (opt-in) | yes | ciphertext, retention deadline | M4 |
| SOS / check-in | yes | ciphertext, recipient circle | M4 |
| Push tokens | no | token, device | M3 |

## Tracking strategy (battery, M2)

| State | Mechanism | Cadence |
|-------|-----------|---------|
| Stationary | Significant-location-change + visits | rare |
| Moving | Standard location updates, reduced accuracy | moderate |
| Driving (CoreMotion automotive) | Best-for-navigation accuracy, live speed | frequent, only while a circle member is watching or an opt-in trip is active |

Viewers register "presence" over the WebSocket. Frequent uploads happen only while someone is watching.

## Retention

- Live location: only the latest value per device (M2).
- History: opt-in per user, retention chosen by the user, deleted automatically by the server (M4).
- Expired invites are purged hourly.
- Deleting a device removes its memberships immediately; circles left empty are deleted.

## Server

- API reference: [API.md](API.md).
- Logs contain method, route pattern, status and duration only: no IPs, bodies, IDs or keys.
- Limits: 64 KiB request body, 500 members per circle (configurable via `LEUCHTTURM_MAX_MEMBERS`), 20 open invites per circle.
- Replay protection keeps nonces in memory, so run **one** server instance.

## Hosting and cost

- Hetzner Cloud, smallest shared-CPU instance (about 4-5 EUR/month), Falkenstein or Nuremberg.
- Docker container behind Caddy (automatic TLS) or any reverse proxy. Serve it at the root of a (sub)domain: the request path is part of the signature.
- SQLite backups (e.g. Litestream to an EU object store) are a later option.

## Licensing split

- `ios/`: MPL-2.0 (compatible with App Store distribution by the project owner)
- everything else: AGPL-3.0 (network use of a modified server requires publishing the changes)
