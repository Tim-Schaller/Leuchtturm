package api

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tim-Schaller/leuchtturm/server/internal/auth"
	"github.com/Tim-Schaller/leuchtturm/server/internal/store"
)

var b64 = base64.RawURLEncoding

type env struct {
	t   *testing.T
	srv *httptest.Server
	now time.Time
}

func newEnv(t *testing.T) *env {
	t.Helper()
	e := &env{t: t, now: time.Unix(1_800_000_000, 0)}
	st, err := store.Open(filepath.Join(t.TempDir(), "api.db"), store.Options{Now: func() time.Time { return e.now }})
	if err != nil {
		t.Fatal(err)
	}
	ver := auth.NewVerifier()
	ver.Now = func() time.Time { return e.now }
	e.srv = httptest.NewServer(NewHandler(Options{Store: st, Verifier: ver}))
	t.Cleanup(func() {
		e.srv.Close()
		st.Close()
	})
	return e
}

type client struct {
	e    *env
	priv ed25519.PrivateKey
	agr  []byte
	id   string
}

func (e *env) newClient() *client {
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		e.t.Fatal(err)
	}
	return &client{e: e, priv: priv, agr: rnd(32)}
}

func newCircleID() string { return b64.EncodeToString(rnd(16)) }

func rnd(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

// do sends a signed request and decodes a JSON response into out (if non-nil).
func (c *client) do(method, uri string, body any, out any) int {
	c.e.t.Helper()
	var raw []byte
	if body != nil {
		var err error
		if raw, err = json.Marshal(body); err != nil {
			c.e.t.Fatal(err)
		}
	}
	req, err := http.NewRequest(method, c.e.srv.URL+uri, bytes.NewReader(raw))
	if err != nil {
		c.e.t.Fatal(err)
	}
	req.Header.Set("Authorization", auth.Sign(c.priv, method, uri, c.e.now.Unix(), rnd(16), raw))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if out != nil && len(data) > 0 {
		if err := json.Unmarshal(data, out); err != nil {
			c.e.t.Fatalf("decode %s %s: %v (%s)", method, uri, err, data)
		}
	}
	return resp.StatusCode
}

func (c *client) register() {
	c.e.t.Helper()
	var out struct {
		DeviceID string `json:"device_id"`
	}
	pub := c.priv.Public().(ed25519.PublicKey)
	code := c.do("POST", "/v1/devices", map[string]string{
		"signing_key": b64.EncodeToString(pub), "agreement_key": b64.EncodeToString(c.agr),
	}, &out)
	if code != http.StatusCreated {
		c.e.t.Fatalf("register: %d", code)
	}
	c.id = out.DeviceID
}

func expect(t *testing.T, got, want int, what string) {
	t.Helper()
	if got != want {
		t.Fatalf("%s: status %d, want %d", what, got, want)
	}
}

func TestHealthzAndInfo(t *testing.T) {
	e := newEnv(t)
	resp, err := http.Get(e.srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	expect(t, resp.StatusCode, 200, "healthz")
	if resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatal("missing Cache-Control")
	}

	resp, err = http.Get(e.srv.URL + "/v1/info")
	if err != nil {
		t.Fatal(err)
	}
	var info map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if info["api"] != Version || info["auth"] != auth.Scheme {
		t.Fatalf("info = %v", info)
	}
}

func TestUnknownRouteIs404(t *testing.T) {
	e := newEnv(t)
	resp, err := http.Get(e.srv.URL + "/nope")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	expect(t, resp.StatusCode, 404, "unknown route")
}

func TestRegisterDevice(t *testing.T) {
	e := newEnv(t)
	c := e.newClient()
	c.register()
	if c.id != store.DeviceID(c.priv.Public().(ed25519.PublicKey)) {
		t.Fatal("device id mismatch")
	}
	pub := c.priv.Public().(ed25519.PublicKey)
	body := map[string]string{"signing_key": b64.EncodeToString(pub), "agreement_key": b64.EncodeToString(c.agr)}
	expect(t, c.do("POST", "/v1/devices", body, nil), 200, "idempotent re-register")

	// signing_key must match the key that signed the request.
	other := e.newClient()
	expect(t, other.do("POST", "/v1/devices", body, nil), 400, "foreign signing key")
}

func TestAuthFailures(t *testing.T) {
	e := newEnv(t)
	c := e.newClient()
	c.register()

	// Unregistered device.
	expect(t, e.newClient().do("GET", "/v1/circles", nil, nil), 401, "unknown device")

	// No Authorization header.
	resp, err := http.Get(e.srv.URL + "/v1/circles")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	expect(t, resp.StatusCode, 401, "no auth")

	// Replay of an identical signed request.
	req, _ := http.NewRequest("GET", e.srv.URL+"/v1/circles", nil)
	req.Header.Set("Authorization", auth.Sign(c.priv, "GET", "/v1/circles", e.now.Unix(), rnd(16), nil))
	req2 := req.Clone(req.Context())
	r1, _ := http.DefaultClient.Do(req)
	r1.Body.Close()
	expect(t, r1.StatusCode, 200, "first")
	r2, _ := http.DefaultClient.Do(req2)
	r2.Body.Close()
	expect(t, r2.StatusCode, 401, "replay")

	// Stale clock returns server time.
	req, _ = http.NewRequest("GET", e.srv.URL+"/v1/circles", nil)
	req.Header.Set("Authorization", auth.Sign(c.priv, "GET", "/v1/circles", e.now.Unix()-3600, rnd(16), nil))
	r3, _ := http.DefaultClient.Do(req)
	var stale map[string]any
	_ = json.NewDecoder(r3.Body).Decode(&stale)
	r3.Body.Close()
	expect(t, r3.StatusCode, 401, "stale")
	if stale["error"] != "stale_timestamp" || stale["server_time"] == nil {
		t.Fatalf("stale body = %v", stale)
	}

	// Oversized body.
	big := strings.Repeat("a", maxBody+1)
	req, _ = http.NewRequest("POST", e.srv.URL+"/v1/circles", strings.NewReader(big))
	req.Header.Set("Authorization", auth.Sign(c.priv, "POST", "/v1/circles", e.now.Unix(), rnd(16), []byte(big)))
	r4, _ := http.DefaultClient.Do(req)
	r4.Body.Close()
	expect(t, r4.StatusCode, 413, "too large")
}

func TestCircleInviteRotateFlow(t *testing.T) {
	e := newEnv(t)
	alice, bob, carol, mallory := e.newClient(), e.newClient(), e.newClient(), e.newClient()
	for _, c := range []*client{alice, bob, carol, mallory} {
		c.register()
	}

	// Alice creates a circle.
	var created struct {
		CircleID string `json:"circle_id"`
		Epoch    int64  `json:"epoch"`
	}
	expect(t, alice.do("POST", "/v1/circles", map[string]string{
		"circle_id": "bad",
		"meta_blob": "AA", "member_blob": "AA", "wrapped_key": "AA",
	}, nil), 400, "invalid circle id")
	expect(t, alice.do("POST", "/v1/circles", map[string]string{
		"circle_id":   newCircleID(),
		"meta_blob":   b64.EncodeToString([]byte("meta-1")),
		"member_blob": b64.EncodeToString([]byte("alice-card")),
		"wrapped_key": b64.EncodeToString([]byte("k1-alice")),
	}, &created), 201, "create circle")
	cid := created.CircleID
	if created.Epoch != 1 {
		t.Fatalf("epoch = %d", created.Epoch)
	}

	expect(t, alice.do("POST", "/v1/circles", map[string]string{"circle_id": newCircleID(), "meta_blob": "AA", "member_blob": "", "wrapped_key": "AA"}, nil), 400, "empty blob")
	expect(t, mallory.do("GET", "/v1/circles/"+cid, nil, nil), 404, "non-member get")

	invite := func(maxUses int) (string, []byte) {
		token := rnd(32)
		h := sha256.Sum256(token)
		var out struct {
			InviteID string `json:"invite_id"`
		}
		var d struct {
			Epoch int64 `json:"epoch"`
		}
		alice.do("GET", "/v1/circles/"+cid, nil, &d)
		expect(t, alice.do("POST", "/v1/circles/"+cid+"/invites", map[string]any{
			"epoch":              d.Epoch,
			"auth_token_hash":    b64.EncodeToString(h[:]),
			"sealed_circle_key":  b64.EncodeToString([]byte("sealed-k1")),
			"expires_in_seconds": 3600,
			"max_uses":           maxUses,
		}, &out), 201, "create invite")
		return out.InviteID, token
	}
	expect(t, mallory.do("POST", "/v1/circles/"+cid+"/invites", map[string]any{
		"epoch": 1, "auth_token_hash": b64.EncodeToString(rnd(32)), "sealed_circle_key": "AA",
	}, nil), 404, "non-member invite")
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/invites", map[string]any{
		"epoch": 7, "auth_token_hash": b64.EncodeToString(rnd(32)), "sealed_circle_key": "AA",
	}, nil), 409, "stale epoch invite")
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/invites", map[string]any{
		"auth_token_hash": b64.EncodeToString(rnd(32)), "sealed_circle_key": "AA", "max_uses": 51,
	}, nil), 400, "too many uses")

	redeem := func(c *client, inviteID string, token []byte) (int, map[string]any) {
		var out map[string]any
		code := c.do("POST", "/v1/invites/"+inviteID+"/redeem", map[string]string{
			"auth_token":  b64.EncodeToString(token),
			"member_blob": b64.EncodeToString([]byte("card")),
		}, &out)
		return code, out
	}

	inv, tok := invite(2)
	if code, _ := redeem(bob, inv, rnd(32)); code != 404 {
		t.Fatalf("wrong token: %d", code)
	}
	code, out := redeem(bob, inv, tok)
	expect(t, code, 200, "bob redeem")
	if out["circle_id"] != cid || out["sealed_circle_key"] != b64.EncodeToString([]byte("sealed-k1")) {
		t.Fatalf("redeem out = %v", out)
	}
	code, _ = redeem(carol, inv, tok)
	expect(t, code, 200, "carol redeem")
	code, _ = redeem(mallory, inv, tok)
	expect(t, code, 404, "used-up invite")

	// Circle view from Bob.
	var detail struct {
		Epoch   int64 `json:"epoch"`
		Members []struct {
			DeviceID     string `json:"device_id"`
			AgreementKey string `json:"agreement_key"`
			Role         string `json:"role"`
		} `json:"members"`
		MyWrappedKey *string `json:"my_wrapped_key"`
	}
	expect(t, bob.do("GET", "/v1/circles/"+cid, nil, &detail), 200, "bob get")
	if len(detail.Members) != 3 || detail.MyWrappedKey != nil {
		t.Fatalf("detail = %+v", detail)
	}
	if detail.Members[0].Role != "owner" || detail.Members[0].AgreementKey != b64.EncodeToString(alice.agr) {
		t.Fatalf("owner entry = %+v", detail.Members[0])
	}

	// Bob updates his member card.
	expect(t, bob.do("PUT", "/v1/circles/"+cid+"/members/me", map[string]string{
		"member_blob": b64.EncodeToString([]byte("bob-card-v2")),
	}, nil), 204, "update card")

	// Only the owner may remove members; rotation must cover all remaining members.
	expect(t, bob.do("PUT", "/v1/circles/"+cid+"/meta", map[string]string{"meta_blob": "AA"}, nil), 403, "member renames")
	expect(t, alice.do("PUT", "/v1/circles/"+cid+"/meta", map[string]string{
		"meta_blob": b64.EncodeToString([]byte("meta-1b")),
	}, nil), 204, "owner renames")

	rotation := map[string]any{
		"epoch":     2,
		"meta_blob": b64.EncodeToString([]byte("meta-2")),
		"wrapped_keys": []map[string]string{
			{"device_id": alice.id, "wrapped_key": b64.EncodeToString([]byte("k2-alice"))},
			{"device_id": carol.id, "wrapped_key": b64.EncodeToString([]byte("k2-carol"))},
		},
	}
	expect(t, carol.do("POST", "/v1/circles/"+cid+"/members/"+bob.id+"/remove", rotation, nil), 403, "carol removes bob")
	bad := map[string]any{"epoch": 2, "meta_blob": "AA", "wrapped_keys": []map[string]string{
		{"device_id": alice.id, "wrapped_key": b64.EncodeToString([]byte("k2-alice"))},
	}}
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/members/"+bob.id+"/remove", bad, nil), 400, "incomplete rotation")
	stale := map[string]any{"epoch": 5, "meta_blob": "AA", "wrapped_keys": rotation["wrapped_keys"]}
	noMeta := map[string]any{"epoch": 2, "wrapped_keys": rotation["wrapped_keys"]}
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/members/"+bob.id+"/remove", noMeta, nil), 400, "rotation without meta")
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/members/"+bob.id+"/remove", stale, nil), 409, "wrong epoch")

	var rot struct {
		Epoch int64 `json:"epoch"`
	}
	expect(t, alice.do("POST", "/v1/circles/"+cid+"/members/"+bob.id+"/remove", rotation, &rot), 200, "remove bob")
	if rot.Epoch != 2 {
		t.Fatalf("epoch after rotation = %d", rot.Epoch)
	}
	expect(t, bob.do("GET", "/v1/circles/"+cid, nil, nil), 404, "bob after removal")

	var list struct {
		Circles []struct {
			CircleID   string  `json:"circle_id"`
			Epoch      int64   `json:"epoch"`
			MetaBlob   string  `json:"meta_blob"`
			WrappedKey *string `json:"wrapped_key"`
		} `json:"circles"`
	}
	expect(t, carol.do("GET", "/v1/circles", nil, &list), 200, "carol list")
	if len(list.Circles) != 1 || list.Circles[0].Epoch != 2 || list.Circles[0].WrappedKey == nil ||
		list.Circles[0].MetaBlob != b64.EncodeToString([]byte("meta-2")) ||
		*list.Circles[0].WrappedKey != b64.EncodeToString([]byte("k2-carol")) {
		t.Fatalf("carol list = %+v", list)
	}

	// Invites created before the rotation are gone.
	inv2, _ := invite(1)
	expect(t, alice.do("DELETE", "/v1/circles/"+cid+"/invites/"+inv2, nil, nil), 204, "revoke")
	expect(t, alice.do("DELETE", "/v1/circles/"+cid+"/invites/"+inv2, nil, nil), 404, "revoke twice")

	// Carol leaves, Alice deletes her device: circle disappears.
	expect(t, carol.do("POST", "/v1/circles/"+cid+"/leave", nil, nil), 204, "carol leave")
	expect(t, alice.do("DELETE", "/v1/devices/me", nil, nil), 204, "delete device")
	expect(t, alice.do("GET", "/v1/circles", nil, nil), 401, "deleted device")
}

func TestExpiredInviteViaAPI(t *testing.T) {
	e := newEnv(t)
	alice, bob := e.newClient(), e.newClient()
	alice.register()
	bob.register()
	var created struct {
		CircleID string `json:"circle_id"`
	}
	alice.do("POST", "/v1/circles", map[string]string{"circle_id": newCircleID(), "meta_blob": "AA", "member_blob": "AA", "wrapped_key": "AA"}, &created)
	token := rnd(32)
	h := sha256.Sum256(token)
	var inv struct {
		InviteID string `json:"invite_id"`
	}
	expect(t, alice.do("POST", "/v1/circles/"+created.CircleID+"/invites", map[string]any{
		"epoch": 1, "auth_token_hash": b64.EncodeToString(h[:]), "sealed_circle_key": "AA", "expires_in_seconds": 60,
	}, &inv), 201, "invite")

	e.now = e.now.Add(61 * time.Second)
	expect(t, bob.do("POST", "/v1/invites/"+inv.InviteID+"/redeem", map[string]string{
		"auth_token": b64.EncodeToString(token), "member_blob": "AA",
	}, nil), 404, "expired")
}
