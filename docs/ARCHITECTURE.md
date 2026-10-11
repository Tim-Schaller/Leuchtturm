# Architecture

Status: v1 record format for identity, circles and invites on CloudKit (milestone M1). Location sharing (M2+) is still a design. Nothing here has been independently security-reviewed.

## Components

```
┌──────────────────────────────┐        ┌───────────────────────────────────┐
│ iPhone                       │        │ Apple iCloud (CloudKit)           │
│  Leuchtturm app (SwiftUI)    │ ─────► │  owner's private DB: 1 zone/circle│
│   └ LeuchtturmCore           │ ◄───── │  zone-wide CKShare (public link)  │
│      crypto, records, client │        │  members: shared DB               │
└──────────────────────────────┘        └───────────────────────────────────┘
```

- **App** (`ios/Leuchtturm`): SwiftUI, iOS 26+, Liquid Glass. UI and app state only. Debug builds can swap CloudKit and the Keychain for the in-memory simulation with made-up members (`ios/Leuchtturm/Simulation`, launch argument `-simulation`); release builds do not contain that code.
- **LeuchtturmCore** (`ios/LeuchtturmCore`): all cryptography, record formats, the `CircleBackend` abstraction with a **CloudKit** implementation and an **in-memory simulation** for tests, and the high-level `LeuchtturmClient`. The logic is tested on Linux (swift-crypto) and macOS (CryptoKit).
- **No server of our own.** CloudKit stores records and handles sharing.

## CloudKit layout

- Each circle is a **custom record zone** named after the circle ID (16 random bytes, base64url) in the **owner's private database**.
- The zone is shared with a **zone-wide `CKShare`** with `publicPermission = readWrite`, so anyone with the share URL can join the zone. The share title is the generic string "Leuchtturm" (Apple can read it).
- Members access the zone through their **shared database**. Leaving = deleting the share from the shared database. Removing = the owner removes the participant from the share.
- In a zone share, **every participant can create, overwrite and delete every record**. CloudKit enforces nothing finer. Leuchtturm therefore decides membership and authenticity cryptographically (below) and treats iCloud only as storage and transport.

## Identity

- On first launch each iPhone generates an **Ed25519** signing key and an **X25519** agreement key (CryptoKit).
- Keys live in the **Keychain** with `AfterFirstUnlockThisDeviceOnly`: readable in the background after the first unlock, never synced to iCloud, not restored to other devices. Not in the Secure Enclave, which only supports P-256.
- **Device ID** = first 16 bytes of SHA-256(Ed25519 public key), base64url.
- **Safety code**: 12 hex digits from a device's two public keys, for comparing in person.
- The iCloud account is not part of the cryptographic identity. It only determines zone access.

## Trust anchor: the owner's device

The device that creates a circle is its owner. Its public keys are **pinned** on every member device:
- the creator pins its own keys;
- a joiner learns them from the invite payload, which is authenticated by the invite secret (see Invites).

Everything else is verified against the pinned keys. A device without the pin (e.g. after reinstalling the app) cannot verify the circle and needs a new invite.

## Records

`ctx(label, parts...)` = UTF-8 label followed by each part as a 2-byte big-endian length and its UTF-8 bytes. All integers are big-endian.

### `Circle` (record name `circle`, one per zone)

| Field | Content |
|-------|---------|
| `epoch` | key version, starts at 1 |
| `meta` | encrypted `{"name": …, "members": [device IDs]}` (the **roster**) |
| `sig` | Ed25519 by the owner device over `ctx("leuchtturm/v1/circle-record", circleID) ‖ epoch ‖ meta` |

A circle record with a bad signature makes the circle unreadable (`tampered`).

### `Member` (record name = device ID, one per device)

| Field | Content |
|-------|---------|
| `skey`, `akey` | the device's public keys |
| `card` | encrypted `{"name": …}` (member card) |
| `invite`, `proof` | invite ID and admission proof (empty for the owner) |
| `sig` | Ed25519 by **this device** over `ctx("leuchtturm/v1/member-record", circleID, deviceID, inviteID)` followed by each of skey, akey, card, proof as u64 length ‖ bytes |

Member records are **self-authenticating**: the record name must equal the hash of `skey`, and only the holder of that key can produce `sig`. Another participant can delete or replay a record, but cannot forge one.

A member is shown if its device ID is in the signed roster, or (as *pending*) if its admission proof matches an invite on file. The owner's device moves pending members into the roster the next time it opens the circle.

### `KeyWrap` (record name `wrap-<epoch>-<deviceID>`)

The circle key for one device, wrapped with **HPKE in auth mode** (RFC 9180; DHKEM X25519, HKDF-SHA256, ChaCha20-Poly1305):

```
blob = 0x01 | sender device id (16) | enc (32) | ciphertext (32 + 16)
info = ctx("leuchtturm/v1/circle-key", circleID, epoch, recipientDeviceID)
aad  = ctx("leuchtturm/v1/circle-key-sender", senderDeviceID)
```

Recipients accept only wraps from the pinned owner device.

### `Invite` (record name `invite-<inviteID>`)

| Field | Content |
|-------|---------|
| `epoch`, `expires` | plaintext copies for housekeeping |
| `sealed` | ChaCha20-Poly1305 under the invite *enc key*: `0x02 ‖ epoch ‖ expiresAt ‖ circle key ‖ owner Ed25519 key ‖ owner X25519 key`, AAD `ctx("leuchtturm/v1/invite", circleID, inviteID)` |
| `token` | the invite *auth token*, encrypted under the circle key, so members can check admission proofs |

### `Location` (record name `loc-<deviceID>`, one per device)

| Field | Content |
|-------|---------|
| `blob` | encrypted `{"lat": …, "lon": …, "acc": …, "t": …, "bat": …, "chg": …, "fog": …}` (degrees, accuracy in meters, Unix seconds, optional battery percent and charging flag, optional fog size) |
| `sig` | Ed25519 by **this device** over `ctx("leuchtturm/v1/location-record", circleID, deviceID) ‖ blob` |

Readers show a location only for devices in the signed roster, verify `sig` with the key from that device's member record and keep the newest timestamp seen per device, so a participant cannot fake a position or replay an older one. Pending members' locations are ignored until the owner confirms them. Pausing, leaving the circle and being removed delete the record; the owner's device also deletes it when it cleans up a departed member.

**Fog mode** („Nebel“): for a chosen time the device shares only the center of a fixed grid cell about twice the fog size (1, 5 or 25 km) and sets `fog`. A fixed grid instead of random noise keeps repeated updates from averaging out to the real position. The exact position never leaves the device while fog is on; check-ins are disabled.

The app writes the record when the device moved (see Tracking strategy) and reads the selected circle every 30 seconds while the map is open (push updates come later).

### `Note` (record name `note-<noteID>`)

Reactions, quick notes, check-ins and good-mornings.

| Field | Content |
|-------|---------|
| `from` | device ID of the sender |
| `blob` | encrypted `{"k": kind, "x": text, "to": recipient device ID or null, "t": Unix seconds, "loc": {"lat", "lon", "acc"} for check-ins}` |
| `sig` | Ed25519 by the **sending device** over `ctx("leuchtturm/v1/note-record", circleID, noteID, from) ‖ blob` |

Readers accept notes only from devices in the signed roster (or their own), check `sig` against the sender's member record and ignore notes older than 7 days. Text is at most 120 characters. A sender deletes its own notes older than 2 days when it sends a new one; removal and the owner's cleanup delete a departed member's notes. Every member can read every note of the circle, including those addressed to someone else.

Notifications are posted locally by the receiving app after it fetched and decrypted the note. Nothing readable goes through Apple's push service.

### `Place` (record name `place-<placeID>`)

| Field | Content |
|-------|---------|
| `from` | device ID of the member who created it |
| `blob` | encrypted `{"n": name, "e": emoji, "lat", "lon", "r": radius in meters (50 to 2000)}` |
| `sig` | Ed25519 by the **creating device** over `ctx("leuchtturm/v1/place-record", circleID, placeID, from) ‖ blob` |

Readers accept places only from roster devices and check `sig`. After a key rotation each creator re-encrypts its own places under the new key, so members who join later can read them. Places of a member who leaves or is removed disappear with them. The app lets the creator and the owner delete a place; iCloud cannot enforce that.

**Arrivals and departures** are detected on each member's own device (`PlaceTracker`): inside when the position is within the radius, outside again only beyond the radius plus max(50 m, accuracy), and nothing while the accuracy is worse than the radius. The first look at a place only records the state. A transition is sent as a `Note` of kind `arrival` or `departure` with the place name; the other members are woken by the silent push and notify locally. Nothing is detected while fog mode is on. Contexts: `ctx("leuchtturm/v1/place", circleID, placeID)`.

## Push

Each device saves two `CKDatabaseSubscription`s (private and shared database) with `shouldSendContentAvailable` only: a silent push without title, text or record data. When it arrives, iOS wakes the app briefly; the app loads its circles, decrypts and verifies new notes and posts local notifications. iOS throttles silent pushes, so delivery can be delayed; the app also checks for news when it uploads its location in the background and every 30 seconds while the map is open. CloudKit does not push a change to the device that made it.

### Encrypted content (meta, cards, tokens, locations, notes)

```
blob      = 0x01 | epoch (u64) | ChaCha20-Poly1305 combined (nonce 12 | ciphertext | tag 16)
aad       = context | 0x01 | epoch
plaintext = u16 length | data | zero padding to a multiple of 64 bytes
```

Contexts: `ctx("leuchtturm/v1/circle-meta", circleID)`, `ctx("leuchtturm/v1/member-card", circleID, deviceID)`, `ctx("leuchtturm/v1/invite-token", circleID, inviteID)`, `ctx("leuchtturm/v1/location", circleID, deviceID)`, `ctx("leuchtturm/v1/note", circleID, noteID)`. Padding hides name lengths.

## Invites

1. A member creates a random 32-byte **secret** and derives, with HKDF-SHA256 (no salt), an **auth token** (info `leuchtturm/v1/invite/auth`) and an **enc key** (info `leuchtturm/v1/invite/enc`).
2. It writes an `Invite` record and reads the zone's share URL.
3. The link `leuchtturm://join?v=2&share=<iCloud share URL>&id=<inviteID>&k=<secret>` is shared privately (QR code or message). Apple never sees the secret.
4. The joiner accepts the iCloud share, decrypts `sealed` with the enc key, checks expiry, pins the owner keys, stores the circle key, and writes its `Member` record with the **admission proof** `HMAC-SHA256(auth token, ctx("leuchtturm/v1/admission", circleID, deviceID) ‖ skey ‖ akey)`.
5. If anything fails, the app leaves the iCloud share again.

Someone with only the share URL can join the zone but has neither the circle key nor a valid proof; members ignore them and the owner sees them as *unverified participants* and can remove them.

## Removing members and key rotation

The owner removes a user (all their devices) in one atomic CloudKit operation:
- new circle record with epoch + 1 and the roster without the removed devices, encrypted under a **fresh key** and signed;
- a `KeyWrap` of the fresh key for every remaining roster device;
- deletion of all old `KeyWrap`s, all `Invite`s (they carry the old key) and all records the removed user created;
- removal of the user from the `CKShare`.

Remaining members unwrap the new key on their next sync and re-encrypt their member card under it. Users who leave on their own are cleaned out of the roster by the owner's device.

The owner cannot leave; deleting the zone deletes the circle for everyone. Ownership cannot be transferred (CloudKit zones belong to one account).

## What is stored where

| Data | Encrypted on device | Visible to Apple |
|------|---------------------|------------------|
| Circle name, roster | yes | ciphertext, padded size |
| Display names | yes | ciphertext, padded size |
| Device public keys, signatures | no (public) | yes |
| Invite expiry times | no | yes |
| Which iCloud accounts share a circle | n/a | **yes**, with real identities |
| When records are written | n/a | yes |
| Live location | yes | ciphertext, padded size, **when and how often it is updated** |
| Places, history, trips, reactions (M3+) | yes | ciphertext, size, time |
| Map area you look at | n/a | Apple Maps sees which map tiles are loaded |

## Tracking strategy (battery, M2)

| State | Mechanism | Cadence |
|-------|-----------|---------|
| Stationary | Significant-location-change + visits | rare |
| Moving | Standard location updates, reduced accuracy | moderate |
| Driving (CoreMotion automotive) | Best-for-navigation accuracy, live speed | frequent, while someone is watching or an opt-in trip is active |

Updates will be delivered through CloudKit subscriptions (silent push), so near-real-time rather than instant.

Current state:
- `CLLocationUpdate.liveUpdates` with a `CLBackgroundActivitySession` while sharing is on. iOS pauses updates while the device is stationary and resumes them on movement; with "Always" access it relaunches a terminated app, which restarts tracking at launch.
- Uploads: app open, after 25 m but at most every 15 s, at least every 2 min while moving; app closed, after 100 m but at most every minute, at least every 10 min while moving. Each upload runs inside a background task so a suspension does not cut it off.
- Not yet: driving mode, visits, geofence wake-ups (CLMonitor, M3) and push.

## License

MPL-2.0 for the whole repository.
