package config

import (
	"log/slog"
	"strings"
	"testing"
	"time"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestLoadDefaults(t *testing.T) {
	c, err := Load(env(map[string]string{"DATABASE_URL": "postgres://x"}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Addr != ":8080" || c.MaxAnswerRunes != 64 || c.DrainDelay != 5*time.Second || c.LogLevel != slog.LevelInfo {
		t.Errorf("defaults wrong: %+v", c)
	}
}

func TestLoadRejects(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		wantErr string
	}{
		{"missing database url", map[string]string{}, "DATABASE_URL is required"},
		{"runes not a number", map[string]string{"DATABASE_URL": "x", "VALIDATOR_MAX_ANSWER_RUNES": "lots"}, "VALIDATOR_MAX_ANSWER_RUNES"},
		{"runes out of range", map[string]string{"DATABASE_URL": "x", "VALIDATOR_MAX_ANSWER_RUNES": "0"}, "from 1 to 256"},
		{"bad duration", map[string]string{"DATABASE_URL": "x", "VALIDATOR_DRAIN_DELAY": "soon"}, "VALIDATOR_DRAIN_DELAY"},
		{"shutdown too short", map[string]string{"DATABASE_URL": "x", "VALIDATOR_SHUTDOWN_TIMEOUT": "10ms"}, "VALIDATOR_SHUTDOWN_TIMEOUT"},
		{"bad log level", map[string]string{"DATABASE_URL": "x", "LOG_LEVEL": "loud"}, "LOG_LEVEL"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Load(env(tt.env))
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("Load() error = %v, want it to mention %q", err, tt.wantErr)
			}
		})
	}
}

func TestLoadReportsEveryProblemAtOnce(t *testing.T) {
	_, err := Load(env(map[string]string{"LOG_LEVEL": "loud", "DB_MAX_CONNS": "0"}))
	for _, want := range []string{"DATABASE_URL", "LOG_LEVEL", "DB_MAX_CONNS"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("error %v doesn't mention %s", err, want)
		}
	}
}
