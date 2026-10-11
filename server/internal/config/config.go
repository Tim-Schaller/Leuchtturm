// Package config loads server configuration from environment variables.
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// Config holds runtime settings for leuchtturmd.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DataDir is where the SQLite database and blobs live.
	DataDir string
	// ShutdownTimeout bounds graceful shutdown.
	ShutdownTimeout time.Duration
	// MaxMembersPerCircle bounds circle size (0 = server default of 500).
	MaxMembersPerCircle int
}

// FromEnv reads configuration from the environment and applies defaults.
func FromEnv() (Config, error) {
	cfg := Config{
		Addr:            getenv("LEUCHTTURM_ADDR", ":8080"),
		DataDir:         getenv("LEUCHTTURM_DATA_DIR", "./data"),
		ShutdownTimeout: 10 * time.Second,
	}
	if v := os.Getenv("LEUCHTTURM_SHUTDOWN_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return Config{}, fmt.Errorf("LEUCHTTURM_SHUTDOWN_TIMEOUT: %w", err)
		}
		cfg.ShutdownTimeout = d
	}
	if v := os.Getenv("LEUCHTTURM_MAX_MEMBERS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 2 {
			return Config{}, fmt.Errorf("LEUCHTTURM_MAX_MEMBERS: must be an integer >= 2")
		}
		cfg.MaxMembersPerCircle = n
	}
	return cfg, nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
