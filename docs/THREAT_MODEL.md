# Threat model

Status: v1 (covers milestone M1: identity, circles, invites). Not independently reviewed.

## Goals

1. A compromised or curious server operator cannot read locations, places, history, circle names or display names.
2. A network attacker cannot read or undetectably modify data.
3. Only current circle members can read a circle's data. Removed members cannot read anything shared after their removal.
4. The project does not collect more data than needed for the features to work.

## Non-goals (not protected against)

- **Metadata.** The server sees which devices exist, who belongs to which circle, who is owner, when devices make requests, padded ciphertext sizes and IP addresses at connection time (and later push tokens). It does not log IPs, but it necessarily sees them.
- **A compromised device.** Malware or physical access with an unlocked phone defeats client-side encryption.
- **A malicious circle member.** Anyone in a circle can read what the circle shares and can screenshot or export it.
- **Coercion and stalking by a trusted person.** Location sharing can be abused. Leuchtturm will show clear sharing indicators and lets users leave a circle at any time, but cannot prevent misuse by someone with physical access to the victim's phone.
- **Traffic analysis by a global network observer.**
- **Apple.** APNs and the App Store are operated by Apple. Push payloads will be opaque to Apple, but delivery timing is visible.

## Assets

- Location data (live and history)
- Places (home, work, etc.)
- Circle names, display names, circle membership
- Device private keys and circle keys (Keychain)
- Invite links (grant membership while valid)

## Threats and mitigations

| Threat | Mitigation | Status |
|--------|------------|--------|
| Server breach leaks content | Server stores only ciphertext and public keys; names are padded to hide length | M1 |
| Server operator reads data | E2EE with keys that never leave devices; geofences evaluated on device | M1 / M3 |
| Stolen credentials | There are none: no passwords, no bearer tokens. Requests are signed with device keys | M1 |
| Request replay or tampering | Signature covers method, path, body hash, time and nonce; nonce cache | M1 |
| Server relabels keys (claims key X belongs to device Y) | Device ID is derived from the signing key; clients verify it | M1 |
| Server moves a member card to another device or replays it under another epoch | Card AAD binds circle, device and epoch header | M1 |
| Server forges a rotated circle key | HPKE auth mode: recipients only accept keys wrapped by a current member | M1 |
| Server silently adds its own device to a circle | It still never receives the circle key unless a member wraps it, which happens on rotation for all listed members. **Mitigation: safety codes** shown for every member, to be compared in person. A later version should warn when unverified members appear | M1 (manual) |
| Invite link intercepted | Links expire (default 24 h), have a use limit (default 1) and can be revoked. The circle key is only released on redeem, so an interceptor shows up in the member list and can be removed (which rotates the key) | M1 |
| Invite created during a rotation carries an old key | Server only accepts invites for the current epoch and revokes all invites on rotation | M1 |
| Removed member keeps reading | Atomic key rotation; server rejects rotations that skip a remaining member | M1 |
| Log leakage | Logs contain only method, route pattern, status and duration | M1 |
| Server learns name lengths | Plaintext padded to 64-byte blocks | M1 |
| Supply chain | Server: one dependency (pure-Go SQLite). App: CryptoKit only. Pinned versions | M1 |

## Known limitations of M1

- **Single device per person.** Losing the phone means losing access; rejoin via a new invite. Multi-device and key backup are open (see ROADMAP).
- **Safety codes are manual.** Nothing warns yet when an unverified member appears.
- **Old keys stay on removed devices.** They can still read what was shared before their removal, by design.
- **Replay cache is in memory.** A server restart within the 2-minute window could accept a replayed request once. Impact is limited because all state-changing requests are idempotent or fail on replay (e.g. used invites, epoch checks).
- **No forward secrecy within an epoch.** Anyone who gets a circle key can decrypt everything encrypted under that epoch. Periodic rotation may be added later.

## Open questions

- Key backup and multi-device sync without weakening E2EE.
- Automatic warnings and verification UX for safety codes.
- Metadata reduction (e.g. sealed sender, padding of request timing).
- Independent security audit before a public App Store launch.
