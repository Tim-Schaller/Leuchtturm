// Command leuchtturmd is the Leuchtturm server.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/Tim-Schaller/leuchtturm/server/internal/api"
	"github.com/Tim-Schaller/leuchtturm/server/internal/auth"
	"github.com/Tim-Schaller/leuchtturm/server/internal/config"
	"github.com/Tim-Schaller/leuchtturm/server/internal/store"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	cfg, err := config.FromEnv()
	if err != nil {
		log.Error("invalid configuration", "err", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		log.Error("cannot create data dir", "err", err)
		os.Exit(1)
	}
	st, err := store.Open(filepath.Join(cfg.DataDir, "leuchtturm.db"), store.Options{
		MaxMembersPerCircle: cfg.MaxMembersPerCircle,
	})
	if err != nil {
		log.Error("cannot open database", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	srv := &http.Server{
		Addr: cfg.Addr,
		Handler: api.NewHandler(api.Options{
			Store:    st,
			Verifier: auth.NewVerifier(),
			Logger:   log,
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 16,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go purgeLoop(ctx, st, log)

	errCh := make(chan error, 1)
	go func() {
		log.Info("leuchtturmd listening", "addr", cfg.Addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("server error", "err", err)
			os.Exit(1)
		}
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Error("shutdown error", "err", err)
			os.Exit(1)
		}
	}
}

// purgeLoop periodically deletes expired invites.
func purgeLoop(ctx context.Context, st *store.Store, log *slog.Logger) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := st.PurgeExpiredInvites(ctx); err != nil {
				log.Error("purge invites", "err", err)
			} else if n > 0 {
				log.Info("purged expired invites", "count", n)
			}
		}
	}
}
