// Package store answers the validator's lookups from Postgres through a connection pool.
package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

// Store implements validate.Store.
type Store struct {
	pool *pgxpool.Pool
}

var _ validate.Store = (*Store)(nil)

// errBadURL replaces pgx's parse error, which quotes the URL with the password redacted only
// on a best-effort basis (pgconn.ParseConfigError). A fixed message can't leak it.
var errBadURL = errors.New("DATABASE_URL isn't a valid Postgres URL")

// Open parses the URL and creates the pool. It doesn't connect: connections open on first
// use, so the process starts (and reports not ready) while the database is still coming up.
func Open(ctx context.Context, url string, maxConns int32) (*Store, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, errBadURL
	}
	cfg.MaxConns = maxConns
	cfg.ConnConfig.RuntimeParams["application_name"] = "rarebit-validator"
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create the pool: %w", err)
	}
	return &Store{pool: pool}, nil
}

// Connect opens a single connection, for `validator migrate`.
func Connect(ctx context.Context, url string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(url)
	if err != nil {
		return nil, errBadURL
	}
	cfg.RuntimeParams["application_name"] = "rarebit-validator-migrate"
	return pgx.ConnectConfig(ctx, cfg)
}

// Close waits for borrowed connections to come back, then closes them all.
func (s *Store) Close() { s.pool.Close() }

// Ready succeeds when the database answers and the word lists have been loaded at least once.
func (s *Store) Ready(ctx context.Context) error {
	var loaded bool
	if err := s.pool.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM content_loads)").Scan(&loaded); err != nil {
		return err
	}
	if !loaded {
		return errors.New("no word lists loaded yet: run `validator migrate`")
	}
	return nil
}

// CategoryExists reports whether the category is loaded.
func (s *Store) CategoryExists(ctx context.Context, category string) (bool, error) {
	var ok bool
	err := s.pool.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM categories WHERE id = $1)", category).Scan(&ok)
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
