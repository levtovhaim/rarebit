// Package config reads the validator's settings from environment variables and validates them
// once at startup, so a bad value fails the process immediately instead of on first use.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// DefaultAddr is the listen address when VALIDATOR_ADDR isn't set.
const DefaultAddr = ":8080"

// Config holds every setting. Field comments name the variable and its default.
type Config struct {
	Addr              string        // VALIDATOR_ADDR, ":8080"
	DatabaseURL       string        // DATABASE_URL, required
	DataDir           string        // VALIDATOR_DATA_DIR, "/data" (migrate only)
	MaxAnswerRunes    int           // VALIDATOR_MAX_ANSWER_RUNES, 64 (1-256)
	FuzzyCandidates   int           // VALIDATOR_FUZZY_CANDIDATES, 500 (1-5000)
	DBMaxConns        int32         // DB_MAX_CONNS, 10 (1-100)
	DrainDelay        time.Duration // VALIDATOR_DRAIN_DELAY, 5s: /readyz is false this long before shutdown
	ShutdownTimeout   time.Duration // VALIDATOR_SHUTDOWN_TIMEOUT, 20s: in-flight requests get this long
	LogLevel          slog.Level    // LOG_LEVEL, info (debug, info, warn, error)
	RequestBodyLimit  int64         // fixed: 4 KiB per request body
	ReadHeaderTimeout time.Duration // fixed: 5s
}

// Load reads the environment through getenv (os.Getenv in production) and returns every
// problem at once.
func Load(getenv func(string) string) (Config, error) {
	c := Config{RequestBodyLimit: 4 << 10, ReadHeaderTimeout: 5 * time.Second}
	var errs []error

	c.Addr = orDefault(getenv("VALIDATOR_ADDR"), DefaultAddr)
	c.DatabaseURL = getenv("DATABASE_URL")
	if c.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL is required"))
	} else if _, err := pgx.ParseConfig(c.DatabaseURL); err != nil {
		// pgx's error quotes the URL; this message can't leak the password.
		errs = append(errs, errors.New("DATABASE_URL isn't a valid Postgres URL"))
	}
	c.DataDir = orDefault(getenv("VALIDATOR_DATA_DIR"), "/data")
	c.MaxAnswerRunes = intIn(getenv, "VALIDATOR_MAX_ANSWER_RUNES", 64, 1, 256, &errs)
	c.FuzzyCandidates = intIn(getenv, "VALIDATOR_FUZZY_CANDIDATES", 500, 1, 5000, &errs)
	c.DBMaxConns = int32(intIn(getenv, "DB_MAX_CONNS", 10, 1, 100, &errs))
	c.DrainDelay = durationIn(getenv, "VALIDATOR_DRAIN_DELAY", 5*time.Second, 0, time.Minute, &errs)
	c.ShutdownTimeout = durationIn(getenv, "VALIDATOR_SHUTDOWN_TIMEOUT", 20*time.Second, time.Second, 5*time.Minute, &errs)

	switch strings.ToLower(orDefault(getenv("LOG_LEVEL"), "info")) {
	case "debug":
		c.LogLevel = slog.LevelDebug
	case "info":
		c.LogLevel = slog.LevelInfo
	case "warn":
		c.LogLevel = slog.LevelWarn
	case "error":
		c.LogLevel = slog.LevelError
	default:
		errs = append(errs, fmt.Errorf("LOG_LEVEL %q: want debug, info, warn or error", getenv("LOG_LEVEL")))
	}
	return c, errors.Join(errs...)
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

func intIn(getenv func(string) string, name string, def, lo, hi int, errs *[]error) int {
	raw := getenv(name)
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v < lo || v > hi {
		*errs = append(*errs, fmt.Errorf("%s %q: want an integer from %d to %d", name, raw, lo, hi))
		return def
	}
	return v
}

func durationIn(getenv func(string) string, name string, def, lo, hi time.Duration, errs *[]error) time.Duration {
	raw := getenv(name)
	if raw == "" {
		return def
	}
	v, err := time.ParseDuration(raw)
	if err != nil || v < lo || v > hi {
		*errs = append(*errs, fmt.Errorf("%s %q: want a duration from %s to %s", name, raw, lo, hi))
		return def
	}
	return v
}
