package store

import (
	"context"
	"strings"
	"testing"
	"time"
)

// The errors end up in logs, so they must never carry the password from DATABASE_URL.
func TestErrorsDontLeakThePassword(t *testing.T) {
	const secret = "s3cret-pw"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tests := []struct {
		name string
		run  func() error
	}{
		{"open, malformed url", func() error {
			_, err := Open(ctx, "postgres://u:"+secret+"@127.0.0.1:notaport/db", 1)
			return err
		}},
		{"connect, malformed url", func() error {
			_, err := Connect(ctx, "postgres://u:"+secret+"@127.0.0.1:notaport/db")
			return err
		}},
		{"connect, nothing listening", func() error {
			_, err := Connect(ctx, "postgres://u:"+secret+"@127.0.0.1:1/db?connect_timeout=2")
			return err
		}},
		{"query, nothing listening", func() error {
			s, err := Open(ctx, "postgres://u:"+secret+"@127.0.0.1:1/db?connect_timeout=2", 1)
			if err != nil {
				return err
			}
			defer s.Close()
			return s.Ready(ctx)
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.run()
			if err == nil {
				t.Fatal("want an error")
			}
			if strings.Contains(err.Error(), secret) {
				t.Errorf("error leaks the password: %v", err)
			}
		})
	}
}
