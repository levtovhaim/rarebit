// Package store answers the validator's lookups from Postgres through a connection pool, and
// opens the connection `validator migrate` uses.
package store

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

// connectTimeout bounds every new connection and every dial. pgx's defaults would allow
// 2 minutes per connection (and a pool keeps dialing after the request that asked for the
// connection gave up), and no limit at all for the dial behind the cancel request it sends
// when a connection breaks; that one holds the broken connection's pool slot for up to 15 s.
const connectTimeout = 2 * time.Second

// errBadURL replaces pgx's parse error, which quotes the URL with the password redacted only
// on a best-effort basis (pgconn.ParseConfigError). A fixed message can't leak it.
var errBadURL = errors.New("DATABASE_URL isn't a valid Postgres URL")

// Store implements validate.Store.
type Store struct {
	pool       *pgxpool.Pool // lookups
	probe      probe         // readiness, outside the pool
	wantSchema int
	schemaOK   atomic.Bool  // the schema and a first load were seen; neither goes back
	normalizer atomic.Value // string: the normalizer version of the latest load, as of the last check
}

var _ validate.Store = (*Store)(nil)

// Open parses the URL and creates the pool. It doesn't connect: connections open on first
// use, so the process starts (and reports not ready) while the database is still coming up.
// wantSchema is the newest migration this binary knows; Ready fails while the schema is older.
func Open(ctx context.Context, url string, maxConns int32, wantSchema int) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, errBadURL
	}
	cfg.MaxConns = maxConns
	limitConnections(cfg.ConnConfig, "rarebit-validator")
	// Limits enforced by Postgres: when a request times out, pgx only closes its socket, and
	// without these the query would keep running (or keep waiting for a lock) on the server.
	cfg.ConnConfig.RuntimeParams["statement_timeout"] = "2500ms"
	cfg.ConnConfig.RuntimeParams["lock_timeout"] = "1s"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create the pool: %w", err)
	}
	probeCfg := cfg.ConnConfig.Copy()
	probeCfg.RuntimeParams["application_name"] = "rarebit-validator-probe"
	return &Store{pool: pool, probe: newProbe(probeCfg), wantSchema: wantSchema}, nil
}

func limitConnections(cfg *pgx.ConnConfig, name string) {
	cfg.ConnectTimeout = connectTimeout
	cfg.DialFunc = (&net.Dialer{Timeout: connectTimeout}).DialContext
	cfg.RuntimeParams["application_name"] = name
}

// Connect opens a single connection, for `validator migrate`. If the Job's pod or node vanishes
// without closing it, Postgres ends the session, and so frees the migration lock, within about
// 30 seconds instead of waiting for the operating system's keepalive (2 hours by default).
func Connect(ctx context.Context, url string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(url)
	if err != nil {
		return nil, errBadURL
	}
	limitConnections(cfg, "rarebit-validator-migrate")
	params := cfg.RuntimeParams
	params["idle_session_timeout"] = "30s"
	params["idle_in_transaction_session_timeout"] = "30s"
	params["tcp_keepalives_idle"] = "10"
	params["tcp_keepalives_interval"] = "5"
	params["tcp_keepalives_count"] = "3"
	params["tcp_user_timeout"] = "30000" // milliseconds
	return pgx.ConnectConfig(ctx, cfg)
}

// Close waits for borrowed connections to come back, then closes them all.
func (s *Store) Close() {
	s.pool.Close()
	s.probe.close()
}

// Ready succeeds when Postgres answers on the probe connection, the schema is at least at this
// binary's newest migration, and the word lists were loaded at least once. Once those two
// hold, later checks only read the latest load's normalizer version (ContentNormalizer).
func (s *Store) Ready(ctx context.Context) error {
	return s.probe.do(ctx, func(conn *pgx.Conn) error {
		if !s.schemaOK.Load() {
			var version int
			var loaded bool
			err := conn.QueryRow(ctx, `SELECT (SELECT coalesce(max(version), 0) FROM schema_migrations),
				EXISTS (SELECT 1 FROM content_loads)`).Scan(&version, &loaded)
			if err != nil {
				return err
			}
			if version < s.wantSchema {
				return fmt.Errorf("the schema is at migration %d and this binary needs %d: run `validator migrate`", version, s.wantSchema)
			}
			if !loaded {
				return errors.New("no word lists loaded yet: run `validator migrate`")
			}
			s.schemaOK.Store(true)
		}
		var normalizer string
		err := conn.QueryRow(ctx, "SELECT normalizer_version FROM content_loads ORDER BY id DESC LIMIT 1").Scan(&normalizer)
		if err != nil {
			return err
		}
		s.normalizer.Store(normalizer)
		return nil
	})
}

// probe is the readiness check's own connection. It isn't a pool: a pool keeps a broken
// connection's slot until pgx finishes closing it, which can take 15 s against an unreachable
// server, and a one-slot pool would fail readiness for all that time. A probe drops a broken
// connection at once and dials a new one within the check's own deadline.
type probe struct {
	cfg  *pgx.ConnConfig
	turn chan struct{} // one check at a time: a pgx.Conn isn't safe for concurrent use
	conn *pgx.Conn
}

func newProbe(cfg *pgx.ConnConfig) probe {
	return probe{cfg: cfg, turn: make(chan struct{}, 1)}
}

func (p *probe) do(ctx context.Context, check func(*pgx.Conn) error) error {
	select {
	case p.turn <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-p.turn }()
	if p.conn == nil || p.conn.IsClosed() {
		conn, err := pgx.ConnectConfig(ctx, p.cfg.Copy())
		if err != nil {
			return err
		}
		p.conn = conn
	}
	err := check(p.conn)
	if p.conn.IsClosed() { // a timeout or a network error; pgx finishes closing it in the background
		p.conn = nil
	}
	return err
}

func (p *probe) close() {
	p.turn <- struct{}{}
	defer func() { <-p.turn }()
	if p.conn != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = p.conn.Close(ctx)
		p.conn = nil
	}
}

// ContentNormalizer is the normalizer version that computed the loaded keys, as of the last
// successful Ready, or "" before one.
func (s *Store) ContentNormalizer() string {
	v, _ := s.normalizer.Load().(string)
	return v
}

// CategoryExists reports whether the category is loaded and not retired.
func (s *Store) CategoryExists(ctx context.Context, category string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM categories WHERE id = $1 AND retired_at IS NULL)", category).Scan(&ok)
	return ok, err
}

// FindByKey returns an entry whose normalized key equals key.
func (s *Store) FindByKey(ctx context.Context, category, key string) (string, bool, error) {
	return s.one(ctx, "SELECT word FROM words WHERE category_id = $1 AND norm_key = $2 ORDER BY word LIMIT 1", category, key)
}

// FindBySpellingKey returns an entry whose spelling key equals spellingKey.
func (s *Store) FindBySpellingKey(ctx context.Context, category, spellingKey string) (string, bool, error) {
	return s.one(ctx, "SELECT word FROM words WHERE category_id = $1 AND spelling_key = $2 ORDER BY word LIMIT 1", category, spellingKey)
}

// FuzzyCandidates returns up to limit entries that start with firstLetter and whose keys have
// minLen to maxLen letters.
func (s *Store) FuzzyCandidates(ctx context.Context, category, firstLetter string, minLen, maxLen, limit int) ([]validate.Candidate, error) {
	rows, err := s.pool.Query(ctx, `SELECT word, norm_key FROM words
		WHERE category_id = $1 AND first_letter = $2 AND key_letters BETWEEN $3 AND $4
		ORDER BY word LIMIT $5`, category, firstLetter, minLen, maxLen, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[validate.Candidate])
}

func (s *Store) one(ctx context.Context, sql string, args ...any) (string, bool, error) {
	var word string
	err := s.pool.QueryRow(ctx, sql, args...).Scan(&word)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	return word, err == nil, err
}
