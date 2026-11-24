package server

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

type fakeValidator struct {
	out validate.Outcome
	err error
}

func (f fakeValidator) Validate(context.Context, string, string, string) (validate.Outcome, error) {
	return f.out, f.err
}

type fakeReady struct{ err error }

func (f fakeReady) Ready(context.Context) error { return f.err }

func newServer(v Validator, ready ReadyChecker) *Server {
	return New(Options{
		Validator: v, Ready: ready, Log: slog.New(slog.NewJSONHandler(io.Discard, nil)),
		Version: Version{Version: "abc1234"}, BodyLimit: 256,
		RequestTimeout: time.Second, ReadyTimeout: time.Second,
	})
}

func do(t *testing.T, s *Server, method, path, body string) (int, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest(method, path, strings.NewReader(body)))
	return rec.Code, rec.Body.String()
}

func TestValidate(t *testing.T) {
	valid := validate.Outcome{Result: validate.Valid, Match: "exact", Entry: "ישראל", Key: "ישראל"}
	tests := []struct {
		name     string
		v        fakeValidator
		body     string
		wantCode int
		wantBody string
	}{
		{"valid", fakeValidator{out: valid}, `{"category":"country","letter":"י","answer":"ישראל"}`, 200, `"result":"valid"`},
		{"malformed json", fakeValidator{}, `{"category":`, 400, `"bad_request"`},
		{"unknown field", fakeValidator{}, `{"category":"c","extra":1}`, 400, `"bad_request"`},
		{"body too large", fakeValidator{}, `{"answer":"` + strings.Repeat("א", 200) + `"}`, 413, `"too_large"`},
		{"unknown category", fakeValidator{err: validate.ErrUnknownCategory}, `{}`, 400, `"unknown_category"`},
		{"bad letter", fakeValidator{err: validate.ErrBadLetter}, `{}`, 400, `"bad_letter"`},
		{"store down", fakeValidator{err: errors.New("connection refused")}, `{}`, 503, `"unavailable"`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, body := do(t, newServer(tt.v, fakeReady{}), "POST", "/v1/validate", tt.body)
			if code != tt.wantCode || !strings.Contains(body, tt.wantBody) {
				t.Errorf("got %d %s, want %d with %s", code, body, tt.wantCode, tt.wantBody)
			}
		})
	}
}

func TestValidateRejectsGet(t *testing.T) {
	if code, _ := do(t, newServer(fakeValidator{}, fakeReady{}), "GET", "/v1/validate", ""); code != http.StatusMethodNotAllowed {
		t.Errorf("GET /v1/validate = %d, want 405", code)
	}
}

func TestReadyz(t *testing.T) {
	s := newServer(fakeValidator{}, fakeReady{})
	if code, _ := do(t, s, "GET", "/readyz", ""); code != 200 {
		t.Errorf("ready: got %d, want 200", code)
	}
	if code, _ := do(t, newServer(fakeValidator{}, fakeReady{errors.New("db down")}), "GET", "/readyz", ""); code != 503 {
		t.Errorf("database down: got %d, want 503", code)
	}
	s.StartDrain()
	if code, body := do(t, s, "GET", "/readyz", ""); code != 503 || !strings.Contains(body, "draining") {
		t.Errorf("draining: got %d %s, want 503 draining", code, body)
	}
	if code, _ := do(t, s, "GET", "/healthz", ""); code != 200 {
		t.Errorf("healthz while draining: got %d, want 200 (liveness must not fail on drain)", code)
	}
}

func TestVersionAndMetrics(t *testing.T) {
	s := newServer(fakeValidator{out: validate.Outcome{Result: validate.Unknown}}, fakeReady{})
	if _, body := do(t, s, "GET", "/version", ""); !strings.Contains(body, `"version":"abc1234"`) {
		t.Errorf("/version = %s", body)
	}
	do(t, s, "POST", "/v1/validate", `{}`)
	_, body := do(t, s, "GET", "/metrics", "")
	for _, want := range []string{
		`validator_answers_total{detail="",result="unknown"} 1`,
		`validator_http_requests_total{code="200",method="post",route="/v1/validate"} 1`,
		`validator_draining 0`,
		`go_goroutines`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("/metrics is missing %s", want)
		}
	}
}
