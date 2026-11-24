// Package server is the validator's HTTP API and its runtime endpoints (/healthz, /readyz,
// /metrics, /version), and runs them with a graceful drain.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net"
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
	// ContentNormalizer is the normalizer version that computed the loaded keys, as of the
	// last successful Ready ("" before one).
	ContentNormalizer() string
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
	Validator         Validator
	Ready             ReadyChecker
	Log               *slog.Logger
	Version           Version
	BodyLimit         int64
	RequestTimeout    time.Duration // per validation, database included
	ReadyTimeout      time.Duration // per readiness check
	ReadHeaderTimeout time.Duration
}

// Drain is the shutdown sequence Run follows once its context ends.
type Drain struct {
	Delay           time.Duration // /readyz fails and keep-alives are off, requests still served
	ShutdownTimeout time.Duration // then in-flight requests get this long
	OnStart         func()        // called when the drain starts, e.g. to restore signal handling
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
	}, func() float64 { return boolGauge(s.draining.Load()) })
	mismatch := prometheus.NewGaugeFunc(prometheus.GaugeOpts{
		Name: "validator_content_normalizer_mismatch",
		Help: "1 when the loaded word-list keys came from another normalizer version than this binary's.",
	}, func() float64 { return boolGauge(s.normalizerMismatch()) })
	reg.MustRegister(requests, duration, s.answers, draining, mismatch)

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

// Run serves on ln until ctx ends, then drains: /readyz fails and keep-alive connections are
// closed after their next response, so clients move to other pods while this one still serves
// for d.Delay; then it stops accepting connections and waits up to d.ShutdownTimeout for the
// requests in flight. It returns nil after a clean drain.
func (s *Server) Run(ctx context.Context, ln net.Listener, d Drain) error {
	srv := &http.Server{
		Handler:           s.handler,
		ReadHeaderTimeout: s.opts.ReadHeaderTimeout,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          slog.NewLogLogger(s.opts.Log.Handler(), slog.LevelWarn),
	}
	failed := make(chan error, 1)
	go func() { failed <- srv.Serve(ln) }()
	s.opts.Log.Info("listening", "addr", ln.Addr().String())

	select {
	case err := <-failed:
		return err
	case <-ctx.Done():
	}
	s.StartDrain()
	srv.SetKeepAlivesEnabled(false)
	if d.OnStart != nil { // after the switches, so anything it triggers sees the server draining
		d.OnStart()
	}
	s.opts.Log.Info("draining", "drain_delay", d.Delay.String(), "shutdown_timeout", d.ShutdownTimeout.String())
	select {
	case err := <-failed:
		return err
	case <-time.After(d.Delay):
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), d.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	s.opts.Log.Info("stopped")
	return nil
}

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
	if s.normalizerMismatch() {
		// Not a readiness failure: during a rollout the old pods would all drop out at once.
		s.opts.Log.Warn("the word lists were keyed by another normalizer version",
			"loaded", s.opts.Ready.ContentNormalizer(), "running", s.opts.Version.Normalizer)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (s *Server) normalizerMismatch() bool {
	loaded := s.opts.Ready.ContentNormalizer()
	return loaded != "" && loaded != s.opts.Version.Normalizer
}

func (s *Server) version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.opts.Version)
}

func boolGauge(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// CheckReady asks a running server's /readyz on this host, for health checks in an image with no
// shell or curl (`validator check-ready`). addr is the server's listen address, as in
// VALIDATOR_ADDR; an empty host means the loopback address.
func CheckReady(addr string, timeout time.Duration) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("listen address %q: %w", addr, err)
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/readyz")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("/readyz returned %d", resp.StatusCode)
	}
	return nil
}
