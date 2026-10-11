# Contributing to Leuchtturm

Thanks for helping. A few ground rules keep the project healthy and its privacy promises intact.

## Privacy rules for contributions

- No analytics, tracking or advertising SDKs. No network calls other than Apple services (CloudKit, APNs, StoreKit).
- Location, places, history and names must be encrypted on the device before they are written to CloudKit. Never store plaintext personal data in a record.
- Every record must be verifiable: owner-signed (circle) or self-signed (member data). Never trust a record because CloudKit returned it.
- Geofence evaluation stays on the device.
- Do not log personal data.

## Workflow

1. Open an issue before starting larger work.
2. Fork, create a branch, make your change, add tests.
3. Run the tests: `cd ios/LeuchtturmCore && swift test` (works on macOS and Linux). Changes to record formats must update [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and, if key derivation changes, the test vectors.
4. Open a pull request with a clear description.

## Licensing of contributions

All contributions are made under the **MPL-2.0**.

## Contributor License Agreement (CLA)

Because the app is distributed through the Apple App Store, and the project owner may need to relicense or dual-license code in the future, every contributor must agree to the following by stating **"I agree to the Leuchtturm CLA"** in their first pull request:

1. You confirm that you wrote the contribution or have the right to submit it.
2. You keep the copyright in your contribution.
3. You grant Tim Schaller (the project owner) a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, modify, sublicense and distribute your contribution, including under licenses other than the one the project currently uses, and including in binaries distributed through app stores.
4. Your contribution is provided "as is", without warranty.

An automated CLA bot may replace this manual statement later.

## Code of conduct

Be respectful. Harassment and discrimination are not tolerated.
