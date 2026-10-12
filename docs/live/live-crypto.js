// Opens a Leuchtturm live location. Shared by the page and the vector check
// (docs/test-vectors/check-live.mjs); format in docs/ARCHITECTURE.md.

export function base64UrlDecode(text) {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  try {
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

export function base64Decode(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** "#p.<id>.<key>" -> { environment, id, key } or null. */
export function parseFragment(hash) {
  const parts = hash.replace(/^#/, "").split(".");
  if (parts.length !== 3 || !["d", "p"].includes(parts[0])) return null;
  const id = base64UrlDecode(parts[1]);
  const key = base64UrlDecode(parts[2]);
  if (!id || id.length !== 16 || !key || key.length !== 32) return null;
  return { environment: parts[0], id: parts[1], key };
}

/** AES-256-GCM: nonce (12) | ciphertext | tag (16), AAD "leuchtturm/v1/live" + id. */
export async function openLive(blob, link) {
  const key = await crypto.subtle.importKey("raw", link.key, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: blob.slice(0, 12), additionalData: new TextEncoder().encode("leuchtturm/v1/live" + link.id), tagLength: 128 },
    key,
    blob.slice(12),
  );
  const p = JSON.parse(new TextDecoder().decode(plain));
  const isNumber = (x) => typeof x === "number" && Number.isFinite(x);
  if (p.v !== 1 || typeof p.n !== "string" || !isNumber(p.la) || !isNumber(p.lo) || Math.abs(p.la) > 90 || Math.abs(p.lo) > 180
      || !isNumber(p.ac) || !isNumber(p.t) || !isNumber(p.e)) {
    throw new Error("malformed");
  }
  return {
    name: p.n.slice(0, 60),
    latitude: p.la,
    longitude: p.lo,
    accuracy: p.ac,
    timestamp: new Date(p.t * 1000),
    battery: isNumber(p.b) ? p.b : null,
    expires: new Date(p.e * 1000),
  };
}
