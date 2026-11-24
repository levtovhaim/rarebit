// Package server is the validator's HTTP API and its runtime endpoints: /healthz, /readyz,
// /metrics and /version.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

// Validator checks one answer (validate.Validator in production).
type Validator interface {
	Validate(ctx context.Context, category, letter, answer string) (validate.Outcome, error)
}

// ReadyChecker reports whether the dependencies can serve requests (store.Store in production).
type ReadyChecker interface {
	Ready(ctx context.Context) error
}

// Version is what /version reports.
type Version struct {
	Version    string `json:"version"`
	Normalizer string `json:"normalizer"`
	Unicode    string `json:"unicode"`
	Go         string `json:"go"`
}

// Options configures a Server.
type Options struct {
	Validator      Validator
	Ready          ReadyChecker
	Log            *slog.Logger
	Version        Version
	BodyLimit      int64
	RequestTimeout time.Duration // per validation, database included
	ReadyTimeout   time.Duration // per readiness check
}

// Server serves the API. Create it with New.
type Server struct {
	opts     Options
	draining atomic.Bool
	answers  *prometheus.CounterVec
	handler  http.Handler
}

// New builds the handler and registers the metrics on a registry of its own.
func New(opts Options) *Server {
	s := &Server{opts: opts}
	reg := prometheus.NewRegistry()
	reg.MustRegister(collectors.NewGoCollector(), collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}))

	requests := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "validator_http_requests_total", Help: "HTTP requests by route, method and status code.",
	}, []string{"route", "method", "code"})
	duration := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name: "validator_http_request_duration_seconds", Help: "HTTP request latency by route and status code.",
		Buckets: []float64{.001, .0025, .005, .01, .025, .05, .1, .25, .5, 1, 2.5},
	}, []string{"route", "code"})
	s.answers = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "validator_answers_total",
		Help: "Validated answers by result, and by match (valid) or reason (invalid).",
	}, []string{"result", "detail"})
	draining := prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "validator_draining", Help: "1 while the process is shutting down and /readyz fails.",
	}, func() float64 {
		if s.draining.Load() {
			return 1
		}
		return 0
	})
	reg.MustRegister(requests, duration, s.answers, draining)

	mux := http.NewServeMux()
	route := func(pattern, name string, h http.HandlerFunc) {
		labels := prometheus.Labels{"route": name}
		mux.Handle(pattern, promhttp.InstrumentHandlerDuration(duration.MustCurryWith(labels),
			promhttp.InstrumentHandlerCounter(requests.MustCurryWith(labels), h)))
	}
	route("POST /v1/validate", "/v1/validate", s.validate)
	route("GET /healthz", "/healthz", s.healthz)
	route("GET /readyz", "/readyz", s.readyz)
	route("GET /version", "/version", s.version)
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))
	s.handler = mux
	return s
}

// Handler is the root HTTP handler.
func (s *Server) Handler() http.Handler { return s.handler }

// StartDrain makes /readyz fail, so the load balancer stops sending new requests while the
// ones in flight finish.
func (s *Server) StartDrain() { s.draining.Store(true) }

type request struct {
	Category string `json:"category"`
	Letter   string `json:"letter"`
	Answer   string `json:"answer"`
}

type apiError struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

func (s *Server) validate(w http.ResponseWriter, r *http.Request) {
	var req request
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, s.opts.BodyLimit))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeJSON(w, http.StatusRequestEntityTooLarge, apiError{"too_large", "request body is too large"})
			return
		}
		writeJSON(w, http.StatusBadRequest, apiError{"bad_request", "body must be {category, letter, answer}"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.opts.RequestTimeout)
	defer cancel()
	out, err := s.opts.Validator.Validate(ctx, req.Category, req.Letter, req.Answer)
	switch {
	case errors.Is(err, validate.ErrUnknownCategory):
		writeJSON(w, http.StatusBadRequest, apiError{"unknown_category", err.Error()})
		return
	case errors.Is(err, validate.ErrBadLetter):
		writeJSON(w, http.StatusBadRequest, apiError{"bad_letter", err.Error()})
		return
	case err != nil:
		// The answer text stays out of the logs: it's player input.
		s.opts.Log.Error("validation failed", "category", req.Category, "err", err)
		writeJSON(w, http.StatusServiceUnavailable, apiError{"unavailable", "the word lists can't be read right now"})
		return
	}
	detail := out.Match
	if out.Result == validate.Invalid {
		detail = out.Reason
	}
	s.answers.WithLabelValues(string(out.Result), detail).Inc()
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	if s.draining.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.opts.ReadyTimeout)
	defer cancel()
	if err := s.opts.Ready.Ready(ctx); err != nil {
		s.opts.Log.Warn("not ready", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "not_ready"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.opts.Version)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
