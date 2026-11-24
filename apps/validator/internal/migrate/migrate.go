// Package migrate applies the SQL migrations embedded in the binary, in order, each in its own
// transaction. A Postgres advisory lock makes concurrent runs (two Jobs, a retry) wait for each
// other, and a checksum per migration catches a migration edited after it was applied.
package migrate

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"regexp"
	"sort"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

//go:embed migrations/*.sql
var embedded embed.FS

// lockKey identifies the migration lock among the database's advisory locks.
const lockKey int64 = 0x7261_7265_6269_7401 // "rarebit" + 1

// Migration is one SQL file, NNNN_name.sql.
type Migration struct {
	Version  int
	Name     string
	SQL      string
	Checksum string
}

var fileName = regexp.MustCompile(`^(\d{4})_([a-z0-9_]+)\.sql$`)

// Embedded returns the migrations built into the binary, sorted, numbered 1, 2, 3, ...
func Embedded() ([]Migration, error) {
	return parse(embedded, "migrations")
}

func parse(fsys fs.FS, dir string) ([]Migration, error) {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return nil, err
	}
	var out []Migration
	for _, e := range entries {
		m := fileName.FindStringSubmatch(e.Name())
		if m == nil {
			return nil, fmt.Errorf("migration %q: name must be NNNN_name.sql", e.Name())
		}
		body, err := fs.ReadFile(fsys, path.Join(dir, e.Name()))
		if err != nil {
			return nil, err
		}
		v, _ := strconv.Atoi(m[1])
		sum := sha256.Sum256(body)
		out = append(out, Migration{Version: v, Name: m[2], SQL: string(body), Checksum: hex.EncodeToString(sum[:])})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Version < out[j].Version })
	for i, m := range out {
		if m.Version != i+1 {
			return nil, fmt.Errorf("migration %04d_%s: versions must run 1, 2, 3, ... without gaps", m.Version, m.Name)
		}
	}
	return out, nil
}

// lockTimeout caps how long a migration waits for a table lock once it holds the migration
// lock. DDL waiting behind a long reader would otherwise make every new reader queue behind
// it; failing fast lets the Job retry instead.
const lockTimeout = "5s"

// Lock takes the migration lock on conn, waiting while another run holds it (or until ctx ends),
// then limits the session's table-lock waits to lockTimeout. The lock belongs to the session,
// so a run that dies releases it when Postgres ends its session (store.Connect keeps that short).
func Lock(ctx context.Context, conn *pgx.Conn) (unlock func(), err error) {
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockKey); err != nil {
		return nil, fmt.Errorf("take the migration lock: %w", err)
	}
	unlock = func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		_, _ = conn.Exec(ctx, "SELECT pg_advisory_unlock($1)", lockKey)
	}
	if _, err := conn.Exec(ctx, "SET lock_timeout = '"+lockTimeout+"'"); err != nil {
		unlock()
		return nil, err
	}
	return unlock, nil
}

// Up applies the migrations that aren't applied yet and returns how many it applied. Call it
// while holding Lock.
func Up(ctx context.Context, conn *pgx.Conn, migrations []Migration, log *slog.Logger) (int, error) {
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version    int PRIMARY KEY,
		name       text NOT NULL,
		checksum   text NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return 0, fmt.Errorf("create schema_migrations: %w", err)
	}
	rows, err := conn.Query(ctx, "SELECT version, checksum FROM schema_migrations")
	if err != nil {
		return 0, err
	}
	type row struct {
		Version  int
		Checksum string
	}
	done, err := pgx.CollectRows(rows, pgx.RowToStructByPos[row]) // closes rows on every path
	if err != nil {
		return 0, err
	}
	applied := map[int]string{}
	for _, r := range done {
		applied[r.Version] = r.Checksum
	}

	n := 0
	for _, m := range migrations {
		if sum, ok := applied[m.Version]; ok {
			if sum != m.Checksum {
				return n, fmt.Errorf("migration %04d_%s changed after it was applied: add a new migration instead", m.Version, m.Name)
			}
			continue
		}
		err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, m.SQL); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)",
				m.Version, m.Name, m.Checksum)
			return err
		})
		if err != nil {
			return n, fmt.Errorf("migration %04d_%s: %w", m.Version, m.Name, err)
		}
		log.Info("migration applied", "migration", m.Version, "name", m.Name)
		n++
	}
	if newest := len(migrations); len(applied) > newest {
		// An older image after a rollback: its code must still work with the newer schema.
		log.Warn("database has migrations this binary doesn't know", "binary_newest", newest, "database_count", len(applied))
	}
	return n, nil
}
