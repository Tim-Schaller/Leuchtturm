// Package api contains the HTTP handlers of the Tandem server.
//
// Privacy rule: handlers must never log request bodies, coordinates,
// names or full client IP addresses.
package api

import (
	"encoding/json"
	"net/http"
)

// Version is the API version prefix served by this build.
const Version = "v1"

// NewHandler returns the root HTTP handler.
func NewHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	mux.HandleFunc("GET /v1/info", info)
	return secureHeaders(mux)
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func info(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"name":    "tandem",
		"api":     Version,
		"license": "AGPL-3.0",
		"source":  "https://github.com/Tim-Schaller/tandem",
	})
}

func secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
