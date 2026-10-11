// Package api contains the HTTP handlers of the Leuchtturm server.
//
// Privacy rule: handlers must never log request bodies, coordinates,
// names or client IP addresses.
package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/Tim-Schaller/leuchtturm/server/internal/auth"
	"github.com/Tim-Schaller/leuchtturm/server/internal/store"
)

// Version is the API version prefix served by this build.
const Version = "v1"

// maxBody bounds request bodies. All payloads are small, opaque blobs.
const maxBody = 64 << 10

// Field size limits (decoded bytes).
const (
	keyLen          = 32
	maxMemberBlob   = 2048
	maxMetaBlob     = 2048
	maxWrappedKey   = 512
	maxSealedKey    = 512
	defaultInvite   = 24 * time.Hour
	minInviteTTL    = time.Minute
	maxInviteTTL    = 7 * 24 * time.Hour
	maxInviteUses   = 50
	defaultInvUses  = 1
	maxRotationKeys = 1000
)

// Options configures the handler.
type Options struct {
	Store    *store.Store
	Verifier *auth.Verifier
	Logger   *slog.Logger
}

// Server holds handler dependencies.
type Server struct {
	store *store.Store
	ver   *auth.Verifier
	log   *slog.Logger
}

// NewHandler returns the root HTTP handler.
func NewHandler(o Options) http.Handler {
	s := &Server{store: o.Store, ver: o.Verifier, log: o.Logger}
	if s.log == nil {
		s.log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if s.ver == nil {
		s.ver = auth.NewVerifier()
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /v1/info", s.info)

	mux.Handle("POST /v1/devices", s.selfSigned(s.registerDevice))
	mux.Handle("DELETE /v1/devices/me", s.authed(s.deleteDevice))

	mux.Handle("POST /v1/circles", s.authed(s.createCircle))
	mux.Handle("GET /v1/circles", s.authed(s.listCircles))
	mux.Handle("GET /v1/circles/{id}", s.authed(s.getCircle))
	mux.Handle("PUT /v1/circles/{id}/members/me", s.authed(s.updateMemberBlob))
	mux.Handle("PUT /v1/circles/{id}/meta", s.authed(s.updateCircleMeta))
	mux.Handle("POST /v1/circles/{id}/leave", s.authed(s.leaveCircle))
	mux.Handle("POST /v1/circles/{id}/members/{device}/remove", s.authed(s.removeMember))
	mux.Handle("POST /v1/circles/{id}/invites", s.authed(s.createInvite))
	mux.Handle("DELETE /v1/circles/{id}/invites/{invite}", s.authed(s.revokeInvite))
	mux.Handle("POST /v1/invites/{invite}/redeem", s.authed(s.redeemInvite))

	return s.recoverer(s.logRequests(secureHeaders(mux)))
}

// --- public endpoints ------------------------------------------------------

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	if s.store != nil {
		if err := s.store.Ping(r.Context()); err != nil {
			writeError(w, http.StatusServiceUnavailable, "unavailable", "database unavailable")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) info(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"name":    "leuchtturm",
		"api":     Version,
		"auth":    auth.Scheme,
		"license": "AGPL-3.0",
		"source":  "https://github.com/Tim-Schaller/leuchtturm",
		"time":    s.ver.Now().Unix(),
	})
}

// --- devices ---------------------------------------------------------------

type registerDeviceReq struct {
	SigningKey   bytesB64 `json:"signing_key"`
	AgreementKey bytesB64 `json:"agreement_key"`
}

func (s *Server) registerDevice(w http.ResponseWriter, r *http.Request, key ed25519.PublicKey, body []byte) {
	var req registerDeviceReq
	if !decode(w, body, &req) {
		return
	}
	if len(req.SigningKey) != keyLen || len(req.AgreementKey) != keyLen || !bytes.Equal(req.SigningKey, key) {
		writeError(w, http.StatusBadRequest, "bad_request", "keys must be 32 bytes and signing_key must match the request signature")
		return
	}
	dev, created, err := s.store.RegisterDevice(r.Context(), req.SigningKey, req.AgreementKey)
	if err != nil {
		s.storeError(w, err)
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]string{"device_id": dev.ID})
}

func (s *Server) deleteDevice(w http.ResponseWriter, r *http.Request, dev store.Device, _ []byte) {
	if err := s.store.DeleteDevice(r.Context(), dev.ID); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- circles ---------------------------------------------------------------

type createCircleReq struct {
	CircleID   string   `json:"circle_id"`
	MetaBlob   bytesB64 `json:"meta_blob"`
	MemberBlob bytesB64 `json:"member_blob"`
	WrappedKey bytesB64 `json:"wrapped_key"`
}

func (s *Server) createCircle(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req createCircleReq
	if !decode(w, body, &req) {
		return
	}
	if !sizeOK(w, "meta_blob", req.MetaBlob, 1, maxMetaBlob) ||
		!sizeOK(w, "member_blob", req.MemberBlob, 1, maxMemberBlob) ||
		!sizeOK(w, "wrapped_key", req.WrappedKey, 1, maxWrappedKey) {
		return
	}
	if !store.ValidID(req.CircleID) {
		writeError(w, http.StatusBadRequest, "bad_request", "circle_id must be 16 bytes, base64url")
		return
	}
	id, epoch, err := s.store.CreateCircle(r.Context(), req.CircleID, dev.ID, req.MetaBlob, req.MemberBlob, req.WrappedKey)
	if err != nil {
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"circle_id": id, "epoch": epoch})
}

type circleSummaryResp struct {
	CircleID   string   `json:"circle_id"`
	Epoch      int64    `json:"epoch"`
	Role       string   `json:"role"`
	MetaBlob   bytesB64 `json:"meta_blob"`
	WrappedKey bytesB64 `json:"wrapped_key"`
}

func (s *Server) listCircles(w http.ResponseWriter, r *http.Request, dev store.Device, _ []byte) {
	list, err := s.store.ListCircles(r.Context(), dev.ID)
	if err != nil {
		s.storeError(w, err)
		return
	}
	out := make([]circleSummaryResp, 0, len(list))
	for _, c := range list {
		out = append(out, circleSummaryResp{CircleID: c.ID, Epoch: c.Epoch, Role: c.Role, MetaBlob: c.MetaBlob, WrappedKey: c.WrappedKey})
	}
	writeJSON(w, http.StatusOK, map[string]any{"circles": out})
}

type memberResp struct {
	DeviceID     string   `json:"device_id"`
	SigningKey   bytesB64 `json:"signing_key"`
	AgreementKey bytesB64 `json:"agreement_key"`
	Role         string   `json:"role"`
	MemberBlob   bytesB64 `json:"member_blob"`
	JoinedAt     int64    `json:"joined_at"`
}

func (s *Server) getCircle(w http.ResponseWriter, r *http.Request, dev store.Device, _ []byte) {
	c, err := s.store.GetCircle(r.Context(), r.PathValue("id"), dev.ID)
	if err != nil {
		s.storeError(w, err)
		return
	}
	members := make([]memberResp, 0, len(c.Members))
	for _, m := range c.Members {
		members = append(members, memberResp{
			DeviceID: m.DeviceID, SigningKey: m.SigningKey, AgreementKey: m.AgreementKey,
			Role: m.Role, MemberBlob: m.MemberBlob, JoinedAt: m.JoinedAt.Unix(),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"circle_id":      c.ID,
		"epoch":          c.Epoch,
		"meta_blob":      bytesB64(c.MetaBlob),
		"my_wrapped_key": bytesB64(c.MyWrappedKey),
		"members":        members,
	})
}

type memberBlobReq struct {
	MemberBlob bytesB64 `json:"member_blob"`
}

func (s *Server) updateMemberBlob(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req memberBlobReq
	if !decode(w, body, &req) || !sizeOK(w, "member_blob", req.MemberBlob, 1, maxMemberBlob) {
		return
	}
	if err := s.store.UpdateMemberBlob(r.Context(), r.PathValue("id"), dev.ID, req.MemberBlob); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type metaBlobReq struct {
	MetaBlob bytesB64 `json:"meta_blob"`
}

func (s *Server) updateCircleMeta(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req metaBlobReq
	if !decode(w, body, &req) || !sizeOK(w, "meta_blob", req.MetaBlob, 1, maxMetaBlob) {
		return
	}
	if err := s.store.UpdateCircleMeta(r.Context(), r.PathValue("id"), dev.ID, req.MetaBlob); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) leaveCircle(w http.ResponseWriter, r *http.Request, dev store.Device, _ []byte) {
	if err := s.store.Leave(r.Context(), r.PathValue("id"), dev.ID); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type removeMemberReq struct {
	Epoch       int64    `json:"epoch"`
	MetaBlob    bytesB64 `json:"meta_blob"`
	WrappedKeys []struct {
		DeviceID   string   `json:"device_id"`
		WrappedKey bytesB64 `json:"wrapped_key"`
	} `json:"wrapped_keys"`
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req removeMemberReq
	if !decode(w, body, &req) || !sizeOK(w, "meta_blob", req.MetaBlob, 1, maxMetaBlob) {
		return
	}
	if len(req.WrappedKeys) > maxRotationKeys {
		writeError(w, http.StatusBadRequest, "bad_request", "too many wrapped keys")
		return
	}
	wrapped := make(map[string][]byte, len(req.WrappedKeys))
	for _, wk := range req.WrappedKeys {
		if !sizeOK(w, "wrapped_key", wk.WrappedKey, 1, maxWrappedKey) {
			return
		}
		if _, dup := wrapped[wk.DeviceID]; dup {
			writeError(w, http.StatusBadRequest, "bad_request", "duplicate device in wrapped_keys")
			return
		}
		wrapped[wk.DeviceID] = wk.WrappedKey
	}
	epoch, err := s.store.RemoveMember(r.Context(), r.PathValue("id"), dev.ID, r.PathValue("device"), req.Epoch, req.MetaBlob, wrapped)
	if err != nil {
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"epoch": epoch})
}

// --- invites ---------------------------------------------------------------

type createInviteReq struct {
	Epoch           int64    `json:"epoch"`
	AuthTokenHash   bytesB64 `json:"auth_token_hash"`
	SealedCircleKey bytesB64 `json:"sealed_circle_key"`
	ExpiresIn       int64    `json:"expires_in_seconds"`
	MaxUses         int      `json:"max_uses"`
}

func (s *Server) createInvite(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req createInviteReq
	if !decode(w, body, &req) {
		return
	}
	if len(req.AuthTokenHash) != 32 {
		writeError(w, http.StatusBadRequest, "bad_request", "auth_token_hash must be 32 bytes")
		return
	}
	if !sizeOK(w, "sealed_circle_key", req.SealedCircleKey, 1, maxSealedKey) {
		return
	}
	ttl := defaultInvite
	if req.ExpiresIn != 0 {
		ttl = time.Duration(req.ExpiresIn) * time.Second
	}
	if ttl < minInviteTTL || ttl > maxInviteTTL {
		writeError(w, http.StatusBadRequest, "bad_request", "expires_in_seconds must be between 60 and 604800")
		return
	}
	uses := req.MaxUses
	if uses == 0 {
		uses = defaultInvUses
	}
	if uses < 1 || uses > maxInviteUses {
		writeError(w, http.StatusBadRequest, "bad_request", "max_uses must be between 1 and 50")
		return
	}
	inv, err := s.store.CreateInvite(r.Context(), r.PathValue("id"), dev.ID, req.Epoch, req.AuthTokenHash, req.SealedCircleKey, ttl, uses)
	if err != nil {
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"invite_id": inv.ID, "expires_at": inv.ExpiresAt.Unix()})
}

func (s *Server) revokeInvite(w http.ResponseWriter, r *http.Request, dev store.Device, _ []byte) {
	if err := s.store.RevokeInvite(r.Context(), r.PathValue("id"), r.PathValue("invite"), dev.ID); err != nil {
		s.storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type redeemReq struct {
	AuthToken  bytesB64 `json:"auth_token"`
	MemberBlob bytesB64 `json:"member_blob"`
}

func (s *Server) redeemInvite(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte) {
	var req redeemReq
	if !decode(w, body, &req) {
		return
	}
	if len(req.AuthToken) != 32 {
		writeError(w, http.StatusBadRequest, "bad_request", "auth_token must be 32 bytes")
		return
	}
	if !sizeOK(w, "member_blob", req.MemberBlob, 1, maxMemberBlob) {
		return
	}
	res, err := s.store.RedeemInvite(r.Context(), r.PathValue("invite"), dev.ID, req.AuthToken, req.MemberBlob)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "invalid_invite", "invite is invalid, expired or used up")
			return
		}
		s.storeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"circle_id":         res.CircleID,
		"epoch":             res.Epoch,
		"role":              res.Role,
		"sealed_circle_key": bytesB64(res.SealedKey),
	})
}

// --- authentication wrappers -----------------------------------------------

type authedFunc func(w http.ResponseWriter, r *http.Request, dev store.Device, body []byte)
type selfSignedFunc func(w http.ResponseWriter, r *http.Request, key ed25519.PublicKey, body []byte)

func (s *Server) selfSigned(fn selfSignedFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key, body, ok := s.verify(w, r)
		if !ok {
			return
		}
		fn(w, r, key, body)
	})
}

func (s *Server) authed(fn authedFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key, body, ok := s.verify(w, r)
		if !ok {
			return
		}
		dev, err := s.store.DeviceBySigningKey(r.Context(), key)
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusUnauthorized, "unknown_device", "device is not registered")
			return
		}
		if err != nil {
			s.storeError(w, err)
			return
		}
		fn(w, r, dev, body)
	})
}

// verify reads the (size-limited) body and checks the request signature.
func (s *Server) verify(w http.ResponseWriter, r *http.Request) (ed25519.PublicKey, []byte, bool) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large", "request body too large")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request", "cannot read body")
		}
		return nil, nil, false
	}
	key, err := s.ver.Verify(r.Method, requestURI(r), r.Header.Get("Authorization"), body)
	switch {
	case err == nil:
		return key, body, true
	case errors.Is(err, auth.ErrStale):
		writeJSON(w, http.StatusUnauthorized, map[string]any{
			"error": "stale_timestamp", "message": "clock differs too much from the server",
			"server_time": s.ver.Now().Unix(),
		})
	case errors.Is(err, auth.ErrBusy):
		writeError(w, http.StatusServiceUnavailable, "busy", "server is busy, retry shortly")
	default:
		writeError(w, http.StatusUnauthorized, "unauthorized", "authentication failed")
	}
	return nil, nil, false
}

func requestURI(r *http.Request) string {
	if r.RequestURI != "" {
		return r.RequestURI
	}
	return r.URL.RequestURI()
}

// --- middleware ------------------------------------------------------------

func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// logRequests logs method, route pattern, status and duration only.
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		s.log.LogAttrs(context.Background(), slog.LevelInfo, "request",
			slog.String("method", r.Method),
			slog.String("route", r.Pattern),
			slog.Int("status", sw.status),
			slog.Duration("dur", time.Since(start)))
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				s.log.Error("panic in handler", "panic", v)
				writeError(w, http.StatusInternalServerError, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// --- helpers ---------------------------------------------------------------

func (s *Server) storeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "not_found", "not found")
	case errors.Is(err, store.ErrConflict):
		writeError(w, http.StatusConflict, "conflict", "conflicts with current state")
	case errors.Is(err, store.ErrForbidden):
		writeError(w, http.StatusForbidden, "forbidden", "not allowed")
	case errors.Is(err, store.ErrInvalid):
		writeError(w, http.StatusBadRequest, "bad_request", "invalid request")
	case errors.Is(err, store.ErrLimit):
		writeError(w, http.StatusTooManyRequests, "limit_reached", "limit reached")
	default:
		s.log.Error("store error", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
	}
}

func decode(w http.ResponseWriter, body []byte, v any) bool {
	if err := json.Unmarshal(body, v); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "invalid JSON body")
		return false
	}
	return true
}

func sizeOK(w http.ResponseWriter, name string, b []byte, min, max int) bool {
	if len(b) < min || len(b) > max {
		writeError(w, http.StatusBadRequest, "bad_request", name+" has invalid size")
		return false
	}
	return true
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": code, "message": msg})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// bytesB64 is a byte slice that marshals as unpadded base64url JSON string.
type bytesB64 []byte

func (b bytesB64) MarshalJSON() ([]byte, error) {
	if b == nil {
		return []byte("null"), nil
	}
	return json.Marshal(base64.RawURLEncoding.EncodeToString(b))
}

func (b *bytesB64) UnmarshalJSON(data []byte) error {
	if string(data) == "null" {
		*b = nil
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err != nil {
		return err
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return err
	}
	*b = raw
	return nil
}
