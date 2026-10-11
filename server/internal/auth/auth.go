// Package auth implements Leuchtturm's request authentication (scheme "LT1").
//
// Every request is signed with the device's Ed25519 signing key:
//
//	Authorization: LT1 key=<b64url>,ts=<unix seconds>,nonce=<b64url 16 bytes>,sig=<b64url>
//
// The signature covers a canonical string binding method, request URI, time,
// nonce and the SHA-256 of the body (see Canonical). There are no passwords or
// bearer tokens: the server stores only public keys.
package auth

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Scheme is the Authorization scheme name and canonical-string version tag.
const Scheme = "LT1"

// Errors returned by Verifier.Verify.
var (
	ErrMissing      = errors.New("missing authorization")
	ErrMalformed    = errors.New("malformed authorization")
	ErrStale        = errors.New("timestamp outside allowed window")
	ErrBadSignature = errors.New("bad signature")
	ErrReplay       = errors.New("replayed request")
	ErrBusy         = errors.New("too many recent requests")
)

var b64 = base64.RawURLEncoding

// Canonical returns the byte string that is signed for a request.
//
//	LT1\n<METHOD>\n<request URI>\n<ts>\n<nonce as sent>\n<hex sha256(body)>
func Canonical(method, requestURI string, ts int64, nonce string, body []byte) []byte {
	sum := sha256.Sum256(body)
	var sb strings.Builder
	sb.WriteString(Scheme)
	sb.WriteByte('\n')
	sb.WriteString(method)
	sb.WriteByte('\n')
	sb.WriteString(requestURI)
	sb.WriteByte('\n')
	sb.WriteString(strconv.FormatInt(ts, 10))
	sb.WriteByte('\n')
	sb.WriteString(nonce)
	sb.WriteByte('\n')
	sb.WriteString(hex.EncodeToString(sum[:]))
	return []byte(sb.String())
}

// Sign builds the Authorization header value for a request. nonce must be
// 16 random bytes. It is used by tests and reference clients.
func Sign(priv ed25519.PrivateKey, method, requestURI string, ts int64, nonce []byte, body []byte) string {
	n := b64.EncodeToString(nonce)
	sig := ed25519.Sign(priv, Canonical(method, requestURI, ts, n, body))
	pub := priv.Public().(ed25519.PublicKey)
	return Scheme + " key=" + b64.EncodeToString(pub) +
		",ts=" + strconv.FormatInt(ts, 10) +
		",nonce=" + n +
		",sig=" + b64.EncodeToString(sig)
}

// Verifier checks signed requests and rejects replays within the time window.
// The nonce cache is in memory, so a single server instance is assumed.
type Verifier struct {
	// Skew is the allowed difference between request and server time.
	Skew time.Duration
	// Now overrides the clock (tests).
	Now func() time.Time
	// MaxNonces bounds the replay cache.
	MaxNonces int

	mu   sync.Mutex
	seen map[string]int64 // key+nonce -> expiry (unix seconds)
}

// NewVerifier returns a Verifier with a 2 minute skew window.
func NewVerifier() *Verifier {
	return &Verifier{
		Skew:      2 * time.Minute,
		Now:       time.Now,
		MaxNonces: 200_000,
		seen:      make(map[string]int64),
	}
}

// Verify authenticates a request and returns the signing public key.
func (v *Verifier) Verify(method, requestURI, header string, body []byte) (ed25519.PublicKey, error) {
	if header == "" {
		return nil, ErrMissing
	}
	rest, ok := strings.CutPrefix(header, Scheme+" ")
	if !ok {
		return nil, ErrMalformed
	}
	fields := map[string]string{}
	for _, part := range strings.Split(rest, ",") {
		k, val, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok || k == "" {
			return nil, ErrMalformed
		}
		if _, dup := fields[k]; dup {
			return nil, ErrMalformed
		}
		fields[k] = val
	}
	pub, err := b64.DecodeString(fields["key"])
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return nil, ErrMalformed
	}
	sig, err := b64.DecodeString(fields["sig"])
	if err != nil || len(sig) != ed25519.SignatureSize {
		return nil, ErrMalformed
	}
	nonceRaw, err := b64.DecodeString(fields["nonce"])
	if err != nil || len(nonceRaw) != 16 {
		return nil, ErrMalformed
	}
	ts, err := strconv.ParseInt(fields["ts"], 10, 64)
	if err != nil {
		return nil, ErrMalformed
	}

	now := v.Now()
	if d := now.Sub(time.Unix(ts, 0)); d > v.Skew || d < -v.Skew {
		return nil, ErrStale
	}
	if !ed25519.Verify(pub, Canonical(method, requestURI, ts, fields["nonce"], body), sig) {
		return nil, ErrBadSignature
	}
	// Only authentic requests may occupy replay-cache space.
	if err := v.remember(fields["key"]+"/"+fields["nonce"], now); err != nil {
		return nil, err
	}
	return ed25519.PublicKey(pub), nil
}

func (v *Verifier) remember(id string, now time.Time) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	nowUnix := now.Unix()
	if exp, ok := v.seen[id]; ok && exp > nowUnix {
		return ErrReplay
	}
	if len(v.seen) >= v.MaxNonces {
		for k, exp := range v.seen {
			if exp <= nowUnix {
				delete(v.seen, k)
			}
		}
		if len(v.seen) >= v.MaxNonces {
			return ErrBusy
		}
	}
	// Keep a nonce for twice the window so it cannot be replayed at either edge.
	v.seen[id] = nowUnix + int64(2*v.Skew/time.Second) + 1
	return nil
}
