package auth

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

var fixedNow = time.Unix(1_800_000_000, 0)

func newVerifier() *Verifier {
	v := NewVerifier()
	v.Now = func() time.Time { return fixedNow }
	return v
}

func newKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

var nonce1 = []byte("0123456789abcdef")

func TestSignVerifyRoundTrip(t *testing.T) {
	priv := newKey(t)
	body := []byte(`{"a":1}`)
	h := Sign(priv, "POST", "/v1/circles", fixedNow.Unix(), nonce1, body)
	pub, err := newVerifier().Verify("POST", "/v1/circles", h, body)
	if err != nil {
		t.Fatal(err)
	}
	if !pub.Equal(priv.Public()) {
		t.Fatal("returned key does not match signer")
	}
}

func TestVerifyRejects(t *testing.T) {
	priv := newKey(t)
	body := []byte("body")
	good := Sign(priv, "POST", "/v1/x", fixedNow.Unix(), nonce1, body)

	tests := []struct {
		name   string
		method string
		uri    string
		header string
		body   []byte
		want   error
	}{
		{"missing", "POST", "/v1/x", "", body, ErrMissing},
		{"wrong scheme", "POST", "/v1/x", "Bearer abc", body, ErrMalformed},
		{"garbage fields", "POST", "/v1/x", "LT1 nonsense", body, ErrMalformed},
		{"tampered body", "POST", "/v1/x", good, []byte("other"), ErrBadSignature},
		{"tampered method", "GET", "/v1/x", good, body, ErrBadSignature},
		{"tampered uri", "POST", "/v1/y", good, body, ErrBadSignature},
		{"stale", "POST", "/v1/x", Sign(priv, "POST", "/v1/x", fixedNow.Unix()-300, nonce1, body), body, ErrStale},
		{"future", "POST", "/v1/x", Sign(priv, "POST", "/v1/x", fixedNow.Unix()+300, nonce1, body), body, ErrStale},
		{"short nonce", "POST", "/v1/x", strings.Replace(good, "nonce=", "nonce=AA", 1), body, ErrMalformed},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := newVerifier().Verify(tc.method, tc.uri, tc.header, tc.body)
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestVerifyRejectsSignatureFromOtherKey(t *testing.T) {
	a, b := newKey(t), newKey(t)
	h := Sign(a, "GET", "/x", fixedNow.Unix(), nonce1, nil)
	// Swap in b's public key but keep a's signature.
	hb := Sign(b, "GET", "/x", fixedNow.Unix(), nonce1, nil)
	keyA := between(h, "key=", ",")
	keyB := between(hb, "key=", ",")
	forged := strings.Replace(h, keyA, keyB, 1)
	if _, err := newVerifier().Verify("GET", "/x", forged, nil); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("err = %v, want ErrBadSignature", err)
	}
}

func TestReplayIsRejected(t *testing.T) {
	priv := newKey(t)
	v := newVerifier()
	h := Sign(priv, "GET", "/x", fixedNow.Unix(), nonce1, nil)
	if _, err := v.Verify("GET", "/x", h, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := v.Verify("GET", "/x", h, nil); !errors.Is(err, ErrReplay) {
		t.Fatalf("err = %v, want ErrReplay", err)
	}
}

func TestNonceCacheIsBoundedAndRecovers(t *testing.T) {
	priv := newKey(t)
	v := newVerifier()
	v.MaxNonces = 2
	now := fixedNow
	v.Now = func() time.Time { return now }

	n := func(i byte) []byte { return append([]byte("nonce-0000000000"[:15]), i) }
	for i := byte(0); i < 2; i++ {
		h := Sign(priv, "GET", "/x", now.Unix(), n(i), nil)
		if _, err := v.Verify("GET", "/x", h, nil); err != nil {
			t.Fatal(err)
		}
	}
	h := Sign(priv, "GET", "/x", now.Unix(), n(9), nil)
	if _, err := v.Verify("GET", "/x", h, nil); !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy", err)
	}
	// After the entries expire there is room again.
	now = now.Add(10 * time.Minute)
	h = Sign(priv, "GET", "/x", now.Unix(), n(9), nil)
	if _, err := v.Verify("GET", "/x", h, nil); err != nil {
		t.Fatalf("after expiry: %v", err)
	}
}

type vector struct {
	SeedHex   string `json:"seed_hex"`
	PublicKey string `json:"public_key"`
	Method    string `json:"method"`
	URI       string `json:"request_uri"`
	TS        int64  `json:"ts"`
	Nonce     string `json:"nonce"`
	Body      string `json:"body"`
	Canonical string `json:"canonical"`
	Header    string `json:"authorization"`
}

// TestSharedVector checks the cross-platform test vector that the iOS client
// verifies as well (docs/test-vectors/auth-v1.json).
func TestSharedVector(t *testing.T) {
	raw, err := os.ReadFile("../../../docs/test-vectors/auth-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Request vector `json:"request"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	v := f.Request
	got := string(Canonical(v.Method, v.URI, v.TS, v.Nonce, []byte(v.Body)))
	if got != v.Canonical {
		t.Fatalf("canonical mismatch:\n got %q\nwant %q", got, v.Canonical)
	}
	vf := NewVerifier()
	vf.Now = func() time.Time { return time.Unix(v.TS, 0) }
	pub, err := vf.Verify(v.Method, v.URI, v.Header, []byte(v.Body))
	if err != nil {
		t.Fatalf("vector does not verify: %v", err)
	}
	if b64.EncodeToString(pub) != v.PublicKey {
		t.Fatalf("public key mismatch")
	}
}

func between(s, start, end string) string {
	i := strings.Index(s, start) + len(start)
	j := strings.Index(s[i:], end)
	return s[i : i+j]
}
