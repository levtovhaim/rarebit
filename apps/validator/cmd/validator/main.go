// Command validator checks game answers against the word lists in Postgres.
//
//	validator serve     the HTTP API (POST /v1/validate) and the runtime endpoints
//	validator migrate   apply the schema migrations, then load data/categories into the database
//	validator version   print the version and exit
//	validator check-ready   exit 0 if the server on this host is ready (for health checks;
//	                        the image has no shell or curl)
//
// Settings come from environment variables (internal/config).
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
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

const usage = "usage: validator serve|migrate|version|check-ready"

const (
	requestTimeout = 3 * time.Second
	readyTimeout   = time.Second
	migrateTimeout = 5 * time.Minute
	closeTimeout   = 3 * time.Second
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(buildVersion())
		return
	case "check-ready": // needs only VALIDATOR_ADDR, not the database settings
		addr := os.Getenv("VALIDATOR_ADDR")
		if addr == "" {
			addr = config.DefaultAddr
		}
		if err := server.CheckReady(addr, 2*time.Second); err != nil {
			fmt.Fprintln(os.Stderr, "not ready:", err)
			os.Exit(1)
		}
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
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Error(os.Args[1]+" failed", "err", err)
		os.Exit(1)
	}
}

func serve(ctx context.Context, stopSignals func(), cfg config.Config, log *slog.Logger) error {
	migrations, err := migrate.Embedded()
	if err != nil {
		return err
	}
	db, err := store.Open(ctx, cfg.DatabaseURL, cfg.DBMaxConns, len(migrations))
	if err != nil {
		return err
	}
	// After Run, in-flight requests are done with their connections. Closing the pool waits for
	// pgx to finish closing broken connections (up to 15 s against an unresponsive server), and
	// the process exits right after anyway, so don't let it eat the pod's grace period.
	defer func() {
		closed := make(chan struct{})
		go func() { db.Close(); close(closed) }()
		select {
		case <-closed:
		case <-time.After(closeTimeout):
			log.Warn("closing the database connections timed out", "timeout", closeTimeout.String())
		}
	}()

	api := server.New(server.Options{
		Validator: validate.New(db, cfg.MaxAnswerRunes, cfg.FuzzyCandidates),
		Catalog:   db,
		Ready:     db,
		Log:       log,
		Version: server.Version{
			Version: buildVersion(), Normalizer: hebrew.Version(), Unicode: hebrew.UnicodeVersion(), Go: runtime.Version(),
		},
		BodyLimit:         cfg.RequestBodyLimit,
		RequestTimeout:    requestTimeout,
		ReadyTimeout:      readyTimeout,
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
	})
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return err
	}
	return api.Run(ctx, ln, server.Drain{
		Delay:           cfg.DrainDelay,
		ShutdownTimeout: cfg.ShutdownTimeout,
		OnStart:         stopSignals, // a second SIGTERM or Ctrl-C now ends the process at once
	})
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
	defer func() { // bounded even when ctx is done: a partitioned network must not hang the Job
		closeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_ = conn.Close(closeCtx)
	}()

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
