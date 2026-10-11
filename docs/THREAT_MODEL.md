# Threat model

Status: draft v0.

## Goals

1. A compromised or curious server operator cannot read locations, places or history.
2. A network attacker cannot read or undetectably modify data.
3. Only current circle members can read a circle's data. Removed members cannot read new data.
4. The project does not collect more data than needed for the features to work.

## Non-goals (not protected against)

- **Metadata.** The server sees who belongs to which circle, when devices upload, message sizes, IP addresses and push tokens.
- **A compromised device.** Malware or physical access with an unlocked phone defeats client-side encryption.
- **A malicious circle member.** Anyone in a circle can read what the circle shares and can screenshot or export it.
- **Coercion and stalking by a trusted person.** Location sharing can be abused. Tandem shows clear sharing indicators and lets users leave a circle or pause sharing at any time, but cannot prevent misuse by someone with physical access to the victim's phone.
- **Traffic analysis by a global network observer.**
- **Apple.** APNs and the App Store are operated by Apple. Push payloads are opaque to Apple, but delivery timing is visible.

## Assets

- Location data (live and history)
- Places (home, work, etc.)
- Circle membership
- Identity keys and circle keys on devices

## Main threats and mitigations

| Threat | Mitigation |
|--------|------------|
| Server breach leaks locations | E2EE, server stores ciphertext only |
| Server operator reads data | E2EE, geofences evaluated on device |
| Server injects fake members | Key fingerprints / safety numbers can be verified in person (planned) |
| Server tampers with messages | Sender signatures verified by receivers |
| Removed member keeps reading | Circle key rotation on removal |
| Stolen account credentials | Account login does not unlock keys. Keys are device-bound |
| Log leakage | No coordinates or full IPs in server logs |
| Supply chain | Minimal dependencies, pinned versions, reproducible Docker build |

## Open questions

- Key backup and multi-device sync without weakening E2EE.
- Safety-number verification UX.
- Sealed-sender or similar metadata reduction.
- Independent security audit before a public App Store launch.
