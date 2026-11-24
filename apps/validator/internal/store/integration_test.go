//go:build integration

// Postgres tests: `make validator-integration` starts a throwaway container and sets
// VALIDATOR_TEST_DATABASE_URL. Each run creates its own database and drops it afterwards.
package store_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/levtovhaim/rarebit/apps/validator/internal/content"
	"github.com/levtovhaim/rarebit/apps/validator/internal/migrate"
	"github.com/levtovhaim/rarebit/apps/validator/internal/store"
	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

var quiet = slog.New(slog.NewJSONHandler(io.Discard, nil))

// freshDatabase creates an empty database and returns its URL.
func freshDatabase(t *testing.T, ctx context.Context) string {
	t.Helper()
	base := os.Getenv("VALIDATOR_TEST_DATABASE_URL")
	if base == "" {
		t.Skip("VALIDATOR_TEST_DATABASE_URL isn't set (run make validator-integration)")
	}
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	name := "validator_it_" + hex.EncodeToString(b)
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), "DROP DATABASE "+name+" WITH (FORCE)")
		_ = admin.Close(context.Background())
	})
	u, _ := url.Parse(base)
	u.Path = "/" + name
	return u.String()
}

func migrateAndLoad(t *testing.T, ctx context.Context, conn *pgx.Conn, set content.Set) (applied int, changed bool) {
	t.Helper()
	ms, err := migrate.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	unlock, err := migrate.Lock(ctx, conn)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if applied, err = migrate.Up(ctx, conn, ms, quiet); err != nil {
		t.Fatal(err)
	}
	if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		changed, err = content.Apply(ctx, tx, set)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return applied, changed
}

func TestMigrateLoadAndValidate(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	dbURL := freshDatabase(t, ctx)
	conn, err := store.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	db, err := store.Open(ctx, dbURL, 4, schemaVersion(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.Ready(ctx); err == nil {
		t.Error("Ready() before migrate succeeded, want an error")
	}
	newer, err := store.Open(ctx, dbURL, 1, schemaVersion(t)+1) // an image ahead of the schema
	if err != nil {
		t.Fatal(err)
	}
	defer newer.Close()
	set, err := content.Read(filepath.Join("..", "..", "..", "..", "data"))
	if err != nil {
		t.Fatal(err)
	}

	applied, changed := migrateAndLoad(t, ctx, conn, set)
	if applied == 0 || !changed {
		t.Fatalf("first run: applied %d, changed %v; want migrations applied and content loaded", applied, changed)
	}
	if applied, changed = migrateAndLoad(t, ctx, conn, set); applied != 0 || changed {
		t.Errorf("second run: applied %d, changed %v; want a no-op", applied, changed)
	}
	if err := db.Ready(ctx); err != nil {
		t.Errorf("Ready() after load: %v", err)
	}
	if got := db.ContentNormalizer(); got == "" {
		t.Error("ContentNormalizer() is empty after a successful Ready")
	}
	if err := newer.Ready(ctx); err == nil || !strings.Contains(err.Error(), "needs") {
		t.Errorf("Ready() for a binary ahead of the schema: err = %v, want the schema version error", err)
	}
	var words int
	if err := conn.QueryRow(ctx, "SELECT count(*) FROM words").Scan(&words); err != nil || words != set.Words {
		t.Errorf("words in the database = %d (%v), want %d", words, err, set.Words)
	}

	v := validate.New(db, 64, 500)
	cases := []struct {
		name, category, letter, answer string
		result                         validate.Result
		match, entry                   string
	}{
		{"exact", "country", "י", "ישראל", validate.Valid, "exact", "ישראל"},
		{"exact with niqqud", "country", "י", "יִשְׂרָאֵל", validate.Valid, "exact", "ישראל"},
		{"variant", "country", "א", "אסטריה", validate.Valid, "variant", "אוסטריה"},
		{"typo", "country", "א", "ארגנתינה", validate.Valid, "fuzzy", "ארגנטינה"},
		{"not listed", "country", "א", "אטלנטיס", validate.Unknown, "", ""},
		{"wrong letter", "country", "ב", "ישראל", validate.Invalid, "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := v.Validate(ctx, c.category, c.letter, c.answer)
			if err != nil {
				t.Fatal(err)
			}
			if got.Result != c.result || got.Match != c.match || got.Entry != c.entry {
				t.Errorf("Validate(%q) = %+v, want %s %s %s", c.answer, got, c.result, c.match, c.entry)
			}
		})
	}
	if _, err := v.Validate(ctx, "planet", "א", "ארץ"); err != validate.ErrUnknownCategory {
		t.Errorf("unknown category: err = %v", err)
	}

	// A category removed from the files is retired: no longer served, its row kept, its words
	// gone. Restoring the file brings it back.
	gone := set.Categories[0].ID
	smaller := set
	smaller.Categories = set.Categories[1:]
	smaller.SHA256 = "changed"
	if _, changed := migrateAndLoad(t, ctx, conn, smaller); !changed {
		t.Error("loading a smaller set changed nothing")
	}
	if ok, _ := db.CategoryExists(ctx, gone); ok {
		t.Errorf("category %s is still served after its file went away", gone)
	}
	var retired bool
	var left int
	if err := conn.QueryRow(ctx, `SELECT retired_at IS NOT NULL, (SELECT count(*) FROM words WHERE category_id = $1)
		FROM categories WHERE id = $1`, gone).Scan(&retired, &left); err != nil || !retired || left != 0 {
		t.Errorf("category %s: retired=%v, %d words left (%v); want its row kept, retired, with no words", gone, retired, left, err)
	}
	if ok, _ := db.CategoryExists(ctx, set.Categories[1].ID); !ok {
		t.Errorf("category %s went away", set.Categories[1].ID)
	}
	if _, changed := migrateAndLoad(t, ctx, conn, set); !changed {
		t.Error("loading the full set again changed nothing")
	}
	if ok, _ := db.CategoryExists(ctx, gone); !ok {
		t.Errorf("category %s didn't come back with its file", gone)
	}
	if err := conn.QueryRow(ctx, "SELECT count(*) FROM words").Scan(&words); err != nil || words != set.Words {
		t.Errorf("words after the restore = %d (%v), want %d", words, err, set.Words)
	}
}

func schemaVersion(t *testing.T) int {
	t.Helper()
	ms, err := migrate.Embedded()
	if err != nil {
		t.Fatal(err)
	}
	return len(ms)
}

// stallProxy forwards TCP connections to target. While stalled, it closes the connections it
// forwards and accepts new ones without ever answering: what a client sees when the database
// host is gone and the network drops its packets (a paused container still answers TCP).
type stallProxy struct {
	ln      net.Listener
	target  string
	stalled atomic.Bool
	mu      sync.Mutex
	conns   []net.Conn
}

func newStallProxy(t *testing.T, target string) *stallProxy {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &stallProxy{ln: ln, target: target}
	t.Cleanup(func() { ln.Close(); p.closeAll() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			p.track(c)
			if !p.stalled.Load() {
				go p.forward(c)
			}
		}
	}()
	return p
}

func (p *stallProxy) track(c net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.conns = append(p.conns, c)
}

func (p *stallProxy) closeAll() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.conns {
		c.Close()
	}
	p.conns = nil
}

func (p *stallProxy) forward(c net.Conn) {
	up, err := net.Dial("tcp", p.target)
	if err != nil {
		c.Close()
		return
	}
	p.track(up)
	go func() { _, _ = io.Copy(up, c); up.Close() }()
	_, _ = io.Copy(c, up)
	c.Close()
}

func (p *stallProxy) stall() {
	p.stalled.Store(true)
	p.closeAll() // the open connections die with the host
}

// While the database doesn't answer, every connection attempt hangs and every broken
// connection's cleanup hangs too. Lookups and readiness must both work again within seconds
// once it's back: not after pgx's 2-minute connect default (hung attempts filling the pool),
// and not after the 15 s a pool slot stays taken while pgx closes a broken connection (a
// one-connection probe pool failed readiness for 16 s here).
func TestPoolRecoversQuicklyAfterADatabaseStall(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	dbURL := freshDatabase(t, ctx)
	conn, err := store.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	set, err := content.Read(filepath.Join("..", "..", "..", "..", "data"))
	if err != nil {
		t.Fatal(err)
	}
	migrateAndLoad(t, ctx, conn, set)

	u, _ := url.Parse(dbURL)
	proxy := newStallProxy(t, u.Host)
	u.Host = proxy.ln.Addr().String()
	db, err := store.Open(ctx, u.String(), 2, schemaVersion(t))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	v := validate.New(db, 64, 500)
	// Both paths, each with its own deadline: the probe connection (Ready) and the pool (Validate).
	check := func(timeout time.Duration) error {
		ready := func() error {
			c, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			return db.Ready(c)
		}
		lookup := func() error {
			c, cancel := context.WithTimeout(ctx, timeout)
			defer cancel()
			_, err := v.Validate(c, "country", "י", "ישראל")
			return err
		}
		return errors.Join(ready(), lookup())
	}
	if err := check(5 * time.Second); err != nil {
		t.Fatalf("before the stall: %v", err)
	}

	proxy.stall()
	for i := 0; i < 4; i++ { // more attempts than pool slots: each leaves a hung connect behind
		if err := check(500 * time.Millisecond); err == nil {
			t.Fatal("a check succeeded while the database was unreachable")
		}
	}
	proxy.stalled.Store(false)
	recovered := time.Now()
	deadline := recovered.Add(5 * time.Second)
	for {
		err := check(time.Second)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("still failing %s after the database came back: %v", time.Since(recovered).Round(time.Millisecond), err)
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Logf("serving again %s after the database came back", time.Since(recovered).Round(time.Millisecond))
}

func TestMigrationLockSerializesRuns(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	dbURL := freshDatabase(t, ctx)
	first, err := store.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close(ctx)
	second, err := store.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close(ctx)

	unlock, err := migrate.Lock(ctx, first)
	if err != nil {
		t.Fatal(err)
	}
	short, cancelShort := context.WithTimeout(ctx, 300*time.Millisecond)
	defer cancelShort()
	if _, err := migrate.Lock(short, second); err == nil {
		t.Fatal("a second run took the lock while the first held it")
	}
	unlock()
	// pgx closes a connection whose query was cancelled, so the next run gets a new one.
	third, err := store.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close(ctx)
	unlockThird, err := migrate.Lock(ctx, third)
	if err != nil {
		t.Fatalf("lock after release: %v", err)
	}
	unlockThird()
}

func TestEditedMigrationIsRejected(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	conn, err := store.Connect(ctx, freshDatabase(t, ctx))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	ms, _ := migrate.Embedded()
	if _, err := migrate.Up(ctx, conn, ms, quiet); err != nil {
		t.Fatal(err)
	}
	ms[0].Checksum = "edited"
	if _, err := migrate.Up(ctx, conn, ms, quiet); err == nil || !strings.Contains(err.Error(), "changed after it was applied") {
		t.Errorf("Up() with an edited migration: err = %v", err)
	}
}
