// Package content reads the word lists in data/categories/*.json, computes each word's keys
// with native/hebrew-normalize, and replaces the database's copy in one transaction. The files
// are checked in CI (data/tools/check_data.py); this package rejects only what would break the
// load or the lookups.
package content

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/levtovhaim/rarebit/apps/validator/internal/hebrew"
	"github.com/levtovhaim/rarebit/apps/validator/internal/validate"
)

// List is one source's words in a category.
type List struct {
	Source    string   `json:"source"`
	License   string   `json:"license"`
	URL       string   `json:"url,omitempty"`
	Query     string   `json:"query,omitempty"`
	Retrieved string   `json:"retrieved,omitempty"`
	Words     []string `json:"words"`
}

// Category is one data/categories/<id>.json file.
type Category struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Lists []List `json:"lists"`
}

// Word is a word-list entry with the keys the lookups use.
type Word struct {
	Word        string
	Key         string
	SpellingKey string // empty when the key has fewer than 3 letters
	FirstLetter string
	Letters     int
}

// Set is everything in the data directory.
type Set struct {
	Categories []Category
	Words      int
	SHA256     string // over every file, in name order: unchanged files give the same hash
}

// Read loads and checks <dir>/categories/*.json.
func Read(dir string) (Set, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "categories", "*.json"))
	if err != nil {
		return Set{}, err
	}
	if len(paths) == 0 {
		return Set{}, fmt.Errorf("no category files in %s", filepath.Join(dir, "categories"))
	}
	sort.Strings(paths)
	var set Set
	hash := sha256.New()
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return Set{}, err
		}
		fmt.Fprintf(hash, "%s\x00%d\x00", filepath.Base(p), len(raw))
		hash.Write(raw)
		c, err := parse(raw, strings.TrimSuffix(filepath.Base(p), ".json"))
		if err != nil {
			return Set{}, fmt.Errorf("%s: %w", filepath.Base(p), err)
		}
		for _, l := range c.Lists {
			set.Words += len(l.Words)
		}
		set.Categories = append(set.Categories, c)
	}
	set.SHA256 = hex.EncodeToString(hash.Sum(nil))
	return set, nil
}

func parse(raw []byte, stem string) (Category, error) {
	var c Category
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, err
	}
	var errs []error
	if c.ID != stem || !validate.CategoryID.MatchString(c.ID) {
		errs = append(errs, fmt.Errorf("id %q must match the file name and %s", c.ID, validate.CategoryID))
	}
	if c.Name == "" {
		errs = append(errs, errors.New("name is empty"))
	}
	if c.Kind != "regular" && c.Kind != "creative" {
		errs = append(errs, fmt.Errorf("kind %q must be regular or creative", c.Kind))
	}
	if len(c.Lists) == 0 {
		errs = append(errs, errors.New("no lists"))
	}
	seen := map[string]bool{}
	for i, l := range c.Lists {
		if l.Source == "" || l.License == "" || len(l.Words) == 0 {
			errs = append(errs, fmt.Errorf("list %d: needs a source, a license and words", i))
		}
		for _, w := range l.Words {
			if seen[w] {
				errs = append(errs, fmt.Errorf("list %d: %q appears twice", i, w))
			}
			seen[w] = true
			if _, err := Keys(w); err != nil {
				errs = append(errs, fmt.Errorf("list %d: %q: %w", i, w, err))
			}
		}
	}
	return c, errors.Join(errs...)
}

// Keys computes the lookup keys of one entry.
func Keys(word string) (Word, error) {
	key, err := hebrew.Normalize(word)
	if err != nil {
		return Word{}, err
	}
	first, _ := utf8.DecodeRuneInString(key)
	if key == "" || !strings.ContainsRune(validate.Letters, first) {
		return Word{}, errors.New("its key must start with one of the 22 round letters")
	}
	w := Word{Word: word, Key: key, FirstLetter: string(first), Letters: utf8.RuneCountInString(key)}
	if w.Letters >= 3 {
		if w.SpellingKey, err = hebrew.SpellingKey(word); err != nil {
			return Word{}, err
		}
	}
	return w, nil
}

// Apply replaces the database's word lists with set inside tx and records the load. A category
// whose file is gone is retired (kept, with its lists emptied), never deleted. It does nothing
// when the latest load has the same files and the same normalizer, so running it on every
// deploy is cheap. Readers keep seeing the previous lists until tx commits.
func Apply(ctx context.Context, tx pgx.Tx, set Set) (changed bool, err error) {
	var lastSHA, lastNormalizer, lastUnicode string
	err = tx.QueryRow(ctx, `SELECT content_sha256, normalizer_version, unicode_version
		FROM content_loads ORDER BY id DESC LIMIT 1`).Scan(&lastSHA, &lastNormalizer, &lastUnicode)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	if lastSHA == set.SHA256 && lastNormalizer == hebrew.Version() && lastUnicode == hebrew.UnicodeVersion() {
		return false, nil
	}

	ids := make([]string, len(set.Categories))
	for i, c := range set.Categories {
		ids[i] = c.ID
	}
	if _, err := tx.Exec(ctx, `UPDATE categories SET retired_at = now()
		WHERE retired_at IS NULL AND NOT (id = ANY($1))`, ids); err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM word_lists
		WHERE category_id IN (SELECT id FROM categories WHERE retired_at IS NOT NULL)`); err != nil {
		return false, err
	}
	for _, c := range set.Categories {
		if err := applyCategory(ctx, tx, c); err != nil {
			return false, fmt.Errorf("category %s: %w", c.ID, err)
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO content_loads
		(categories, words, content_sha256, normalizer_version, unicode_version)
		VALUES ($1, $2, $3, $4, $5)`,
		len(set.Categories), set.Words, set.SHA256, hebrew.Version(), hebrew.UnicodeVersion())
	return err == nil, err
}

func applyCategory(ctx context.Context, tx pgx.Tx, c Category) error {
	if _, err := tx.Exec(ctx, `INSERT INTO categories (id, name, kind) VALUES ($1, $2, $3)
		ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, kind = EXCLUDED.kind, retired_at = NULL`,
		c.ID, c.Name, c.Kind); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "DELETE FROM word_lists WHERE category_id = $1", c.ID); err != nil {
		return err
	}
	var rows [][]any
	for pos, l := range c.Lists {
		var listID int64
		if err := tx.QueryRow(ctx, `INSERT INTO word_lists
			(category_id, position, source, license, url, query, retrieved)
			VALUES ($1, $2, $3, $4, NULLIF($5, ''), NULLIF($6, ''), NULLIF($7, '')) RETURNING id`,
			c.ID, pos, l.Source, l.License, l.URL, l.Query, l.Retrieved).Scan(&listID); err != nil {
			return err
		}
		for _, word := range l.Words {
			w, err := Keys(word)
			if err != nil {
				return fmt.Errorf("%q: %w", word, err)
			}
			var spelling any
			if w.SpellingKey != "" {
				spelling = w.SpellingKey
			}
			rows = append(rows, []any{c.ID, w.Word, w.Key, spelling, w.FirstLetter, w.Letters, listID})
		}
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"words"},
		[]string{"category_id", "word", "norm_key", "spelling_key", "first_letter", "key_letters", "list_id"},
		pgx.CopyFromRows(rows))
	return err
}
