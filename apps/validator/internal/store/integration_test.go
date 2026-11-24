//go:build integration

// Postgres tests: `make validator-integration` starts a throwaway container and sets
// VALIDATOR_TEST_DATABASE_URL. Each run creates its own database and drops it afterwards.
package store_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"
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
	db, err := store.Open(ctx, dbURL, 4)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.Ready(ctx); err == nil {
		t.Error("Ready() before migrate succeeded, want an error")
	}
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

	// A category removed from the files disappears; the others stay.
	smaller := set
	smaller.Categories = set.Categories[1:]
	smaller.SHA256 = "changed"
	if _, changed := migrateAndLoad(t, ctx, conn, smaller); !changed {
		t.Error("loading a smaller set changed nothing")
	}
	if ok, _ := db.CategoryExists(ctx, set.Categories[0].ID); ok {
		t.Errorf("category %s is still there after its file went away", set.Categories[0].ID)
	}
	if ok, _ := db.CategoryExists(ctx, set.Categories[1].ID); !ok {
		t.Errorf("category %s went away", set.Categories[1].ID)
	}
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
