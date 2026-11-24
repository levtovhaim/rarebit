// Command validator checks game answers against the word lists in Postgres.
//
//	validator serve     the HTTP API (POST /v1/validate) and the runtime endpoints
//	validator migrate   apply the schema migrations, then load data/categories into the database
//	validator version   print the version and exit
//
// Settings come from environment variables (internal/config).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"runtime/debug"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/levtovhaim/rarebit/apps/validator/internal/config"
	"github.com/levtovhaim/rarebit/apps/validator/internal/content"
	"github.com/levtovhaim/rarebit/apps/validator/internal/hebrew"
	"github.com/levtovhaim/rarebit/apps/validator/internal/migrate"
	"github.com/levtovhaim/rarebit/apps/validator/internal/server"
	"github.com/levtovhaim/rarebit/apps/validator/internal/store"
	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

// version is the git SHA, set at build time: -ldflags "-X main.version=<sha7>".
var version string

const (
	requestTimeout = 3 * time.Second
	readyTimeout   = time.Second
	migrateTimeout = 5 * time.Minute
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: validator serve|migrate|version")
		os.Exit(2)
	}
	if os.Args[1] == "version" {
		fmt.Println(buildVersion())
		return
	}
	cfg, err := config.Load(os.Getenv)
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel})).
		With("service", "validator", "version", buildVersion())
	if err != nil {
		log.Error("invalid configuration", "err", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	switch os.Args[1] {
	case "serve":
		err = serve(ctx, stop, cfg, log)
	case "migrate":
		err = runMigrate(ctx, cfg, log)
	default:
		fmt.Fprintln(os.Stderr, "usage: validator serve|migrate|version")
		os.Exit(2)
	}
	if err != nil {
		log.Error(os.Args[1]+" failed", "err", err)
		os.Exit(1)
	}
}

func serve(ctx context.Context, stopSignals func(), cfg config.Config, log *slog.Logger) error {
	db, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer db.Close()

	api := server.New(server.Options{
		Validator: validate.New(db, cfg.MaxAnswerRunes, cfg.FuzzyCandidates),
		Ready:     db,
		Log:       log,
		Version: server.Version{
			Version: buildVersion(), Normalizer: hebrew.Version(), Unicode: hebrew.UnicodeVersion(), Go: runtime.Version(),
		},
		BodyLimit:      cfg.RequestBodyLimit,
		RequestTimeout: requestTimeout,
		ReadyTimeout:   readyTimeout,
	})
	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           api.Handler(),
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	failed := make(chan error, 1)
	go func() { failed <- srv.ListenAndServe() }()
	log.Info("listening", "addr", cfg.Addr)

	select {
	case err := <-failed:
		return err
	case <-ctx.Done():
	}
	stopSignals() // a second SIGTERM or Ctrl-C now ends the process at once

	// Fail readiness first and keep serving while the endpoints controller and the load
	// balancer catch up, then stop accepting connections and let in-flight requests finish.
	log.Info("draining", "drain_delay", cfg.DrainDelay.String(), "shutdown_timeout", cfg.ShutdownTimeout.String())
	api.StartDrain()
	select {
	case err := <-failed:
		return err
	case <-time.After(cfg.DrainDelay):
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("shutdown: %w", err)
	}
	log.Info("stopped")
	return nil
}

func runMigrate(ctx context.Context, cfg config.Config, log *slog.Logger) error {
	migrations, err := migrate.Embedded()
	if err != nil {
		return err
	}
	set, err := content.Read(cfg.DataDir) // check the files before touching the database
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, migrateTimeout)
	defer cancel()
	conn, err := store.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer conn.Close(context.WithoutCancel(ctx))

	unlock, err := migrate.Lock(ctx, conn)
	if err != nil {
		return err
	}
	defer unlock()
	applied, err := migrate.Up(ctx, conn, migrations, log)
	if err != nil {
		return err
	}
	var changed bool
	err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		changed, err = content.Apply(ctx, tx, set)
		return err
	})
	if err != nil {
		return fmt.Errorf("load the word lists: %w", err)
	}
	log.Info("migrate done", "migrations_applied", applied, "content_changed", changed,
		"categories", len(set.Categories), "words", set.Words, "content_sha256", set.SHA256)
	return nil
}

// buildVersion is the SHA from -ldflags, else the one the Go toolchain recorded, else "unknown".
func buildVersion() string {
	if version != "" {
		return version
	}
	if info, ok := debug.ReadBuildInfo(); ok {
		var rev, dirty string
		for _, s := range info.Settings {
			switch s.Key {
			case "vcs.revision":
				rev = s.Value
			case "vcs.modified":
				if s.Value == "true" {
					dirty = "-dirty"
				}
			}
		}
		if len(rev) >= 7 {
			return rev[:7] + dirty
		}
	}
	return "unknown"
}
