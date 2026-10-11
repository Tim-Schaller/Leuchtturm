# Contributing to Leuchtturm

Thanks for helping. A few ground rules keep the project healthy and its privacy promises intact.

## Privacy rules for contributions

- No analytics, tracking or advertising SDKs. No third-party network calls from the app other than the Leuchtturm server and Apple services (APNs, StoreKit).
- Location, places and history must be encrypted on the device before upload. Never send plaintext location data to the server.
- Geofence evaluation stays on the device.
- Do not log personal data on the server (no coordinates, no names, no full IP addresses).

## Workflow

1. Open an issue before starting larger work.
2. Fork, create a branch, make your change, add tests.
3. Server: `cd server && go vet ./... && go test ./...`
4. Open a pull request with a clear description.

## Licensing of contributions

- Code in `ios/` is contributed under the **MPL-2.0**.
- All other code and docs are contributed under the **AGPL-3.0**.

## Contributor License Agreement (CLA)

Because the iOS app is distributed through the Apple App Store, and the project owner may need to relicense or dual-license code in the future, every contributor must agree to the following by stating **"I agree to the Leuchtturm CLA"** in their first pull request:

1. You confirm that you wrote the contribution or have the right to submit it.
2. You keep the copyright in your contribution.
3. You grant Tim Schaller (the project owner) a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use, modify, sublicense and distribute your contribution, including under licenses other than the one the project currently uses, and including in binaries distributed through app stores.
4. Your contribution is provided "as is", without warranty.

An automated CLA bot may replace this manual statement later.

## Code of conduct

Be respectful. Harassment and discrimination are not tolerated.
