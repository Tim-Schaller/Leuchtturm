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
- Keys live in the **Keychain**, readable in the background after the first unlock. By default they are **synchronizable** (iCloud Keychain, end-to-end encrypted by Apple), so the user's iPad or a new iPhone has the same identity and circle keys right away. With „Schlüssel nur auf diesem Gerät“ they are stored `ThisDeviceOnly` and never leave the device; switching re-saves all items. Not in the Secure Enclave, which only supports P-256. Devices that share an identity also share one member record; only one of them should share its location (iPads start with sharing paused).
- **Device ID** = first 16 bytes of SHA-256(Ed25519 public key), base64url.
- **Safety code**: 12 hex digits from a device's two public keys, for comparing in person. Each device remembers locally which member devices the user marked as verified, and which devices it has seen per circle: a new device (new member, or a reinstall with a new key) triggers a local notification asking to compare the code.
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
| `meta` | encrypted `{"name": …, "members": [device IDs], "expires": Unix seconds (optional), "admins": [device IDs] (optional)}` (the **roster**; `expires` makes it a temporary circle) |
| `sig` | Ed25519 by the owner device over `ctx("leuchtturm/v1/circle-record", circleID) ‖ epoch ‖ meta` |

A circle record with a bad signature makes the circle unreadable (`tampered`). A temporary circle ends at `expires`: from then on the owner's device deletes the zone and members' devices leave it the next time they list their circles.

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
| `blob` | encrypted `{"lat": …, "lon": …, "acc": …, "t": …, "bat": …, "chg": …, "fog": …, "spd": …}` (degrees, accuracy in meters, Unix seconds, optional battery percent and charging flag, optional fog size, speed while driving) |
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

**Arrivals and departures** are detected on each member's own device (`PlaceTracker`): inside when the position is within the radius, outside again only beyond the radius plus max(50 m, accuracy), and nothing while the accuracy is worse than the radius. The first look at a place only records the state. With "Always" access the places (up to 20) are also registered with `CLMonitor`; an event only wakes the app and resumes location updates, the decision stays with `PlaceTracker`. A transition is sent as a `Note` of kind `arrival` or `departure` with the place name; the other members are woken by the silent push and notify locally. Nothing is detected while fog mode is on. Contexts: `ctx("leuchtturm/v1/place", circleID, placeID)`.

### `History` (record name `hist-<deviceID>-<day>`, one per device and UTC day)

Opt-in, off by default.

| Field | Content |
|-------|---------|
| `from`, `day` | device ID and UTC day `yyyy-MM-dd` (plaintext, needed for deletion) |
| `blob` | encrypted `{"p": [[lat, lon, unix seconds], …]}`, at most 2000 points |
| `sig` | Ed25519 by **this device** over `ctx("leuchtturm/v1/history-record", circleID, deviceID, day) ‖ blob` |

The device records a point when it uploads its location and has moved at least 40 m or 5 minutes passed (never while in fog), keeps today's points in a protected file and rewrites today's record together with the location record in one operation. It deletes its own days older than the chosen retention (1, 7 or 30 days) on the same occasion. Turning history off, leaving a circle and removal delete all of the device's history records. Readers show history only for roster members with a valid signature. Your own history can be exported as an unencrypted GPX file through the share sheet. Context: `ctx("leuchtturm/v1/history", circleID, deviceID, day)`.

### `Trip` (record name `trip-<tripID>`)

Opt-in ("Fahrten teilen"), off by default.

| Field | Content |
|-------|---------|
| `from` | device ID of the driver |
| `blob` | encrypted `{"s": start, "e": end, "d": meters, "v": top speed m/s, "hb": hard brakes, "ra": rapid accelerations, "p": [[lat, lon, t], …] (at most 300)}` |
| `sig` | Ed25519 by the **driver's device** over `ctx("leuchtturm/v1/trip-record", circleID, tripID, from) ‖ blob` |

`TripDetector` runs on the driver's device: a trip starts after two samples at 25 km/h or more within a minute, unless the motion coprocessor (CoreMotion activity, only while trips are shared) says the device is not in a car, and ends three minutes after the last sample at 4 m/s or more; trips under 1 km or 2 minutes are dropped. A hard brake is a deceleration of 3.5 m/s² or more, a rapid acceleration 3 m/s² or more (at most one event per 10 s). Score per trip: 100 − 8 per hard brake − 5 per rapid acceleration − 10 above 130 km/h. While a trip is running and trips are shared, the location record carries the speed (`spd`). The leaderboard is computed on each reader's device from the trips of the last 7 days (distance-weighted score). The driver can delete a single trip ("Ich bin nur mitgefahren"). The driver's device deletes its trips after 30 days, all of them when trip sharing is turned off, and on leaving. Context: `ctx("leuchtturm/v1/trip", circleID, tripID)`.

### "Not arrived yet" alerts

An `ArrivalWatch` (member, place, time, once/weekdays/daily) is stored only on the device that set it, never in iCloud. That device schedules a local time-sensitive notification for every deadline in the next 7 days and withdraws it whenever it loads the circle and sees that the member is inside the place (exact position from today) or sent an arrival note for that place since the start of the day. If the arrival note reaches the device late (throttled silent pushes), the alert can come although the member arrived.

### Place suggestions

With "Always" access iOS reports visits (`CLVisit`). The device keeps finished stays for 30 days in a protected local file, never in iCloud, and suggests spots with stays of 15 minutes or more on at least two different days within 150 m that are not inside a place yet. No reverse geocoding, so no coordinates go to Apple for this.

### Requests and journeys (more `Note` kinds)

Notes carry an optional `"d"` (deadline, Unix seconds).

- `locationRequest` ("Wo bist du?", to one member): the recipient's device, woken by the silent push, takes a fresh position and shares it right away, and the recipient sees who asked.
- `pickUp` ("Hol mich ab"): with the sender's exact position.
- `onMyWay` ("Bin auf dem Weg"): destination name and position, expected arrival in `d` (computed with Apple Maps directions, so Apple sees start and destination for that request). The sender's device sends an `arrival` note within 150 m of the destination.
- `walkHome` ("Heimweg-Begleitung"): destination and latest arrival in `d`. Every other member's device schedules a local alert for `d`, withdrawn when it sees the arrival, a `journeyCancelled` note, or the walker's position at the destination.
- `meetingPoint` ("Treffpunkt"): the centre of everyone's positions (people in fog excluded), optionally a nearby place from an Apple Maps search around that centre.

### Steps, challenges, memories and weather

- **Steps** (opt-in, HealthKit read access): the location payload carries `"stp"` (today) and `"stw"` (last 7 days). The leaderboard and challenges ("70.000 Schritte", "50 km unterwegs" from shared history, a streak of trips without hard braking) are computed on each reader's device.
- **Memories**: the device keeps its own path per day (at most 300 points) in a protected local file, never in iCloud, and shows the day a year, a month or a week ago.
- **Weather**: the current weather at members' positions comes from WeatherKit. Coordinates are rounded to 0.01° (about 1 km) before asking and cached for 30 minutes; Apple sees those rounded places, not who is there.

### Widgets, Live Activity and Siri

The app writes a small snapshot of the selected circle (names, initials, colours, status, the place or "unterwegs", battery, 64 px pictures) as JSON into the App Group container `group.de.timschaller.leuchtturm`, file protection "until first unlock". The widget extension (`LeuchtturmWidgets`) reads only this file, has no keys and no network access to iCloud. The Live Activity shows speed and distance while a trip runs, or destination and arrival time for "Bin auf dem Weg". App Intents ("Wo ist …?", "Nebel einschalten", "Einchecken") read the same snapshot or call into the running app.

### Apple Watch

The watch app (`LeuchtturmWatch`) has no keys. The iPhone sends it the widget snapshot over WatchConnectivity (`updateApplicationContext`, without pictures if it would exceed 50 KB), and the watch keeps the last copy in its own documents folder. SOS and check-in on the watch are messages to the iPhone, which sends them like its own buttons.

### Apple TV (`TVSnapshot`, record name `tv-<tvID>`, private DB, default zone)

The TV app (`LeuchtturmTV`) shows a family map and holds no circle keys. On first launch it creates an X25519 key, a random TV ID (16 bytes) and a pairing secret (32 bytes), kept in its own Keychain (this device only), and shows them as a QR code:

```
leuchtturm://tv?v=1&id=<tv id>&k=<X25519 public key>&s=<secret>
```

The iPhone scans it with the Camera, asks "Apple TV verbinden?" and stores the pairing with its keys. From then on, at most every two minutes when the circle refreshes, it writes one record per paired TV into the user's own **private** database:

| Field | Content |
|-------|---------|
| `blob` | `0x01 | enc (32) | HPKE ciphertext` |

HPKE in **PSK mode** (X25519 / HKDF-SHA256 / ChaCha20-Poly1305) to the TV's key, `info = "leuchtturm/v1/tv-snapshot" ‖ tvID`, PSK = pairing secret, PSK ID = TV ID. The plaintext is `length (u64) | snapshot JSON | zeros` padded to a multiple of 4 KiB; the snapshot is the widget snapshot of the selected circle including the user and coordinates (none for members in fog). The TV fetches the record by name (every 4 s while the code is shown, every minute while the map is) and ignores copies older than the one it shows. "Trennen" on the iPhone deletes the record; "Neuer Code" on the TV makes a new key and deletes the old record.

### Live link (`LiveLocation`, record name `live-<linkID>`, public DB, default zone)

For people without the app, a member can share a web link for one hour:

```
https://tim-schaller.github.io/Leuchtturm/live/#<env>.<link id>.<key>
```

`env` is `d` (CloudKit Development, debug builds) or `p` (Production), the link ID 16 random bytes and the key 32 random bytes, both base64url. Browsers never send the fragment to a server. With every shared position (at most every 20 s, blurred while in fog) the iPhone writes one record to the **public** database:

| Field | Content |
|-------|---------|
| `blob` | `nonce (12) | ciphertext | tag (16)`: AES-256-GCM (CryptoKit combined form), AAD `"leuchtturm/v1/live" ‖ link id` |

The plaintext is JSON `{v: 1, n: name, la, lo, ac: accuracy (m), t: unix s, b: battery?, e: expires}` padded with spaces to a multiple of 256 bytes. Public-database records can be read by anyone and changed only by their creator. The page (`docs/live`, static, GitHub Pages) reads the record through CloudKit Web Services with a read-only API token, decrypts it with WebCrypto and shows name, time, accuracy, battery and an Apple Maps link (a map too, if a MapKit JS token is configured). It refreshes every 20 s and stops when the record is gone or `e` has passed. "Link beenden" deletes the record; so does the app after the hour (on the next location update or launch). AES-GCM rather than ChaCha20 because browsers support it natively. Known-answer vector: `docs/test-vectors/live-v1.json`, checked by the Swift tests and by `node docs/test-vectors/check-live.mjs`.

### Friends by friend code (`FriendCode`, `FriendRequest`, public DB)

A friendship is a circle of two with `"kind": "friend"` in the owner-signed `CircleMeta`; all circle rules apply. It is hidden from the Leuchtturm list and shown in the friends menu and under "Freunde" in the map menu.

Each device has a friend code: 12 Crockford-base32 characters (60 bits), shown as `XXXX-XXXX-XXXX`, also as `leuchtturm://friend?c=…`, and a random 16-byte mailbox ID. Both stay on the device (Keychain).

| Record | Name | Fields |
|--------|------|--------|
| `FriendCode` | `fc-` + base64url(HKDF-SHA256(code, info `leuchtturm/v1/friend-code/id`, 16 bytes)) | `blob`: ChaCha20-Poly1305 under HKDF(code, `leuchtturm/v1/friend-code/key`, 32), AAD = record name, of JSON `{mailbox, name, agreementKey, signingKey}` padded to 256 bytes |
| `FriendRequest` | `fr-` + random | `to`: mailbox ID (queryable), `blob`: `0x01 ‖ enc ‖ HPKE` (base mode, X25519/HKDF-SHA256/ChaCha20-Poly1305) to the card's agreement key, info `ctx("leuchtturm/v1/friend-request", mailbox)`, of JSON `{name, invite, agreementKey, signingKey, timestamp}` padded to 512 bytes |

Adding someone: look up their card by code, create a friendship circle and a 7-day invite, write the request. The recipient's device queries requests for its mailbox (on refresh, at most once a minute), shows name and safety code, and joins with the invite on "Annehmen". The sender's device deletes the request once the friend joined, or after 7 days together with the empty friendship. A new code deletes the old card; requests to the old mailbox are then ignored.

### Low battery

When the device's battery drops to 15 % or less without charging, it sends a `Note` of kind `lowBattery` (text: the percentage) to every circle, once per discharge (again after charging or above 30 %).

### SOS and crash detection

An SOS is a `Note` of kind `sos` to every circle, with the exact position (also in fog mode) and optionally a reason; `safe` gives the all-clear. Receivers post a time-sensitive local notification. Crash detection runs in `TripDetector` on the driver's device: from 40 km/h or more to standstill within about a second (deceleration of 12 m/s² or more, far beyond braking). The app then asks "Alles okay?" in the app and as a time-sensitive notification with "Mir geht's gut" and "Hilfe rufen"; without an answer it sends an SOS with the reason "Möglicher Unfall erkannt" after 60 seconds. There is no call center; the SOS sheet offers a call to 112.

## Push

Each device saves two `CKDatabaseSubscription`s (private and shared database) with `shouldSendContentAvailable` only: a silent push without title, text or record data. When it arrives, iOS wakes the app briefly; the app loads its circles, decrypts and verifies new notes and posts local notifications. iOS throttles silent pushes, so delivery can be delayed; the app also checks for news when it uploads its location in the background and every 30 seconds while the map is open. CloudKit does not push a change to the device that made it.

### Encrypted content (meta, cards, tokens, locations, notes)

```
blob      = 0x01 | epoch (u64) | ChaCha20-Poly1305 combined (nonce 12 | ciphertext | tag 16)
aad       = context | 0x01 | epoch
plaintext = u16 length | data | zero padding to a multiple of 64 bytes
```

Contexts: `ctx("leuchtturm/v1/circle-meta", circleID)`, `ctx("leuchtturm/v1/member-card", circleID, deviceID)`, `ctx("leuchtturm/v1/invite-token", circleID, inviteID)`, `ctx("leuchtturm/v1/location", circleID, deviceID)`, `ctx("leuchtturm/v1/note", circleID, noteID)`. Padding hides name lengths.

### `Profile` (record name `profile-<deviceID>`, one per device)

| Field | Content |
|-------|---------|
| `blob` | encrypted and padded `{"c": colour "#RRGGBB", "e": pin emoji, "bs": banner style, "se": status emoji, "st": status text (≤ 40), "su": status end, "ds": driving totals}` |
| `photo`, `banner` | square JPEG (≤ 120 KB) and wide JPEG (≤ 300 KB), each `0x01 ‖ epoch ‖ ChaCha20-Poly1305` under the circle key, context `ctx("leuchtturm/v1/profile", circleID, deviceID) ‖ "photo"/"banner"`, not padded; empty if none |
| `sig` | Ed25519 by **this device** over `ctx("leuchtturm/v1/profile-record", circleID, deviceID)` followed by blob, photo, banner each as u64 length ‖ bytes |

`ds` is present only with "Fahrten teilen": `{"week"|"month"|"year"|"all": {trips, distance (m), duration (s), topSpeed (m/s), hardBrakes, rapidAccelerations, score}}`. The driver's device computes it after every trip from a local archive of its own trips (`TripArchive`, numbers only, no routes, never uploaded), because `Trip` records stay in iCloud for 30 days only. Readers reject implausible values (e.g. top speed above 150 m/s). The device writes the same profile to all its circles, re-encrypts it after a key rotation and deletes it when leaving. Readers show profiles only of roster members with a valid signature. Apple sees the sizes of the pictures.

### `Message` (record name `msg-<messageID>`)

Chat. Readers accept messages only from roster devices (or their own), check the signature and ignore messages older than 30 days; senders delete their own older ones when sending.

| Field | Content |
|-------|---------|
| `from` | device ID of the sender |
| `blob` | encrypted and padded `{"x": text (≤ 2000), "r": message it replies to, "a": message it reacts to (then `x` is the emoji), "s": sticker flag, "t": Unix milliseconds}` |
| `image` | photo (JPEG) or sticker/Genmoji image (≤ 400 KB), encrypted like profile pictures, context `ctx("leuchtturm/v1/message", circleID, messageID) ‖ "image"`; empty if none |
| `sig` | Ed25519 by the **sending device** over `ctx("leuchtturm/v1/message-record", circleID, messageID, from)` followed by blob and image as u64 length ‖ bytes |

## Roles and takeover

The owner's device stays the only signer of the circle record. It lists **admins** in the signed meta.

- **Requests.** An admin who removes a member or renames the circle sends a signed `Note` of kind `removeRequest` (text: target device ID) or `renameRequest` (text: new name) to the owner. The owner's device carries out requests from listed admins the next time it loads the circle (removal with key rotation as usual) and deletes them. Admins cannot target the owner or other admins; requests from non-admins are ignored.
- **Handover.** The owner makes the chosen member an admin and sends a `handoverOffer` note to them.
- **Takeover.** An admin may take over when the owner offered it, or when the owner's last sign of life (verified location or newest note) is three days old or unknown. CloudKit zones cannot change owner, so the admin's device creates a **new circle**: same name, roster, expiry and places (re-signed by the new owner), admins = old admins minus itself plus the old owner, and a key wrap for every roster device. It then writes a **`Move`** record in the old circle and leaves it, and posts a `tookOver` note in the new one.

### `Move` (record name `move-<signer>`)

| Field | Content |
|-------|---------|
| `from` | device ID of the new owner |
| `blob` | encrypted under the old circle key: `{"c": new circle ID, "u": iCloud share URL, "s": signing key, "a": agreement key, "t": Unix seconds}` |
| `sig` | Ed25519 by the **new owner's device** over `ctx("leuchtturm/v1/move-record", oldCircleID, signer) ‖ blob` |

Members follow a move notice only if the signer is an admin in the (owner-signed) meta, is not the old owner, the signature verifies with the signer's member record, and the announced keys are exactly that member's keys. If several admins took over, the earliest notice wins. Following means: accept the new share, check that it is the announced circle, pin the announced keys as the new owner, load the circle (unwrapping the new key) and leave the old one. The old owner's device follows too, hides the old circle and deletes its zone three days later, so late members can still read the notice. Members who were still pending (not in the roster) are not carried over. Context: `ctx("leuchtturm/v1/move", oldCircleID, signer)`.

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
| Places, history, trips, reactions (M3+) | yes | ciphertext, size, time; for history also the days with records |
| Map area you look at | n/a | Apple Maps sees which map tiles are loaded |
| Apple TV snapshot | yes (HPKE to the TV) | that a TV is paired, padded size, when it is written |
| Friend code card and requests | yes (key from the code; HPKE to the recipient) | that a code exists, which mailbox gets how many requests and when; who wrote a record (iCloud user) |
| Live link | yes (AES-GCM, key only in the link) | that you share a link, when it is updated, and the viewers' IP addresses (CloudKit Web Services); GitHub sees page visits, not the fragment |
| Watch snapshot | no (WatchConnectivity, device to device) | no |

## Tracking strategy (battery, M2)

| State | Mechanism | Cadence |
|-------|-----------|---------|
| Stationary | Significant-location-change + visits | rare |
| Moving | Standard location updates, reduced accuracy | moderate |
| Driving (CoreMotion automotive) | Best-for-navigation accuracy, live speed | frequent, while someone is watching or an opt-in trip is active |

Updates will be delivered through CloudKit subscriptions (silent push), so near-real-time rather than instant.

Current state:
- `CLLocationManager` standard updates (10 m filter in the foreground, 50 m / 100 m accuracy in the background). Background updates only with "Always" access, with `showsBackgroundLocationIndicator = false`, so iOS shows no permanent blue indicator. iOS pauses them while the device is stationary (`pausesLocationUpdatesAutomatically`); significant location changes and visit departures wake the app (also after termination) and updates resume. With "When In Use" iOS would show the indicator the whole time a background app tracks, so tracking stops when the app goes to the background and sharing happens only while it is open.
- Uploads: app open, after 25 m but at most every 15 s, at least every 2 min while moving; app closed, after 100 m but at most every minute, at least every 10 min while moving. Each upload runs inside a background task so a suspension does not cut it off.
- Not yet: driving mode, visits, geofence wake-ups (CLMonitor, M3) and push.

## License

MPL-2.0 for the whole repository.
