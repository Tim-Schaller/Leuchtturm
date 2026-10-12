// Checks the web page's decryption against live-v1.json (written by the
// Swift tests). Run: node docs/test-vectors/check-live.mjs
import { readFileSync } from "node:fs";
import { base64Decode, openLive, parseFragment } from "../live/live-crypto.js";

const vector = JSON.parse(readFileSync(new URL("./live-v1.json", import.meta.url)));
const link = parseFragment(new URL(vector.url).hash);
if (!link) throw new Error("fragment did not parse");
const location = await openLive(base64Decode(vector.blob), link);
const expect = (ok, what) => { if (!ok) { console.error("FAIL:", what); process.exit(1); } };
expect(location.name === vector.name, "name");
expect(location.latitude === vector.latitude && location.longitude === vector.longitude, "coordinates");
expect(location.accuracy === vector.accuracy && location.battery === vector.battery, "accuracy and battery");
expect(location.timestamp.getTime() === vector.timestamp * 1000 && location.expires.getTime() === vector.expires * 1000, "times");
const tampered = base64Decode(vector.blob);
tampered[tampered.length - 1] ^= 1;
expect(await openLive(tampered, link).then(() => false, () => true), "tampered blob must fail");
expect(parseFragment("#p.x.y") === null, "bad fragment");
console.log("live-v1.json opens in WebCrypto");
