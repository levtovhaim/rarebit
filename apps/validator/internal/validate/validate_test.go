package validate

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/levtovhaim/rarebit/apps/validator/internal/hebrew"
)

// fakeStore holds entries per category, keyed the way the real store indexes them.
type fakeStore struct {
	words map[string][]string // category -> entries
	err   error
}

func (f *fakeStore) CategoryExists(_ context.Context, c string) (bool, error) {
	_, ok := f.words[c]
	return ok, f.err
}

func (f *fakeStore) find(c string, keyOf func(string) (string, error), want string) (string, bool, error) {
	if f.err != nil {
		return "", false, f.err
	}
	for _, w := range f.words[c] {
		if k, _ := keyOf(w); k == want {
			return w, true, nil
		}
	}
	return "", false, nil
}

func (f *fakeStore) FindByKey(_ context.Context, c, key string) (string, bool, error) {
	return f.find(c, hebrew.Normalize, key)
}

func (f *fakeStore) FindBySpellingKey(_ context.Context, c, sk string) (string, bool, error) {
	return f.find(c, func(w string) (string, error) {
		if k, _ := hebrew.Normalize(w); len([]rune(k)) < 3 {
			return "", nil
		}
		return hebrew.SpellingKey(w)
	}, sk)
}

func (f *fakeStore) FuzzyCandidates(_ context.Context, c, first string, minLen, maxLen, limit int) ([]Candidate, error) {
	if f.err != nil {
		return nil, f.err
	}
	var out []Candidate
	for _, w := range f.words[c] {
		k, _ := hebrew.Normalize(w)
		r := []rune(k)
		if string(r[0]) == first && len(r) >= minLen && len(r) <= maxLen && len(out) < limit {
			out = append(out, Candidate{Word: w, Key: k})
		}
	}
	return out, nil
}

func TestValidate(t *testing.T) {
	store := &fakeStore{words: map[string][]string{
		"country": {"ישראל", "צרפת", "פריז"},
		"plant":   {"שולחן"}, // not a plant, but it exercises the spelling rule
	}}
	v := New(store, 64, 500)
	tests := []struct {
		name, category, letter, answer string
		want                           Outcome
	}{
		{"exact with niqqud", "country", "י", "יִשְׂרָאֵל", Outcome{Result: Valid, Match: "exact", Entry: "ישראל", Key: "ישראל"}},
		{"variant spelling", "plant", "ש", "שלחן", Outcome{Result: Valid, Match: "variant", Entry: "שולחן", Key: "שלחנ"}},
		{"one-letter typo", "country", "פ", "פאריז", Outcome{Result: Valid, Match: "fuzzy", Entry: "פריז", Key: "פאריז"}},
		{"not in the list", "country", "צ", "צ'ילה", Outcome{Result: Unknown, Key: "צילה"}},
		{"wrong letter", "country", "א", "ישראל", Outcome{Result: Invalid, Reason: "wrong_letter", Key: "ישראל"}},
		{"empty after normalizing", "country", "א", "?!", Outcome{Result: Invalid, Reason: "empty"}},
		{"too long", "country", "א", string(make([]rune, 65)), Outcome{Result: Invalid, Reason: "too_long"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := v.Validate(context.Background(), tt.category, tt.letter, tt.answer)
			if err != nil {
				t.Fatalf("Validate() error: %v", err)
			}
			if got != tt.want {
				t.Errorf("Validate() = %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestValidateRequestErrors(t *testing.T) {
	v := New(&fakeStore{words: map[string][]string{"country": {"ישראל"}}}, 64, 500)
	tests := []struct {
		name, category, letter string
		want                   error
	}{
		{"unknown category", "planet", "א", ErrUnknownCategory},
		{"category with a NUL", "\x00", "א", ErrUnknownCategory},
		{"category in capitals", "Country", "א", ErrUnknownCategory},
		{"category too long", "c" + strings.Repeat("x", 64), "א", ErrUnknownCategory},
		{"final-form letter", "country", "ם", ErrBadLetter},
		{"two letters", "country", "אב", ErrBadLetter},
		{"latin letter", "country", "a", ErrBadLetter},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := v.Validate(context.Background(), tt.category, tt.letter, "אבג"); !errors.Is(err, tt.want) {
				t.Errorf("Validate() error = %v, want %v", err, tt.want)
			}
		})
	}
}

// A malformed id must be rejected before any query: with a failing store, a query would
// surface as the store's error instead of ErrUnknownCategory.
func TestValidateRejectsMalformedCategoriesWithoutAQuery(t *testing.T) {
	v := New(&fakeStore{words: map[string][]string{}, err: errors.New("db down")}, 64, 500)
	for _, c := range []string{"\x00", "", "Country", "c" + strings.Repeat("x", 64), "a b"} {
		if _, err := v.Validate(context.Background(), c, "א", "אבג"); !errors.Is(err, ErrUnknownCategory) {
			t.Errorf("Validate(category %q) error = %v, want ErrUnknownCategory", c, err)
		}
	}
}

func TestValidateStoreErrorsPropagate(t *testing.T) {
	boom := errors.New("db down")
	v := New(&fakeStore{words: map[string][]string{"country": {}}, err: boom}, 64, 500)
	if _, err := v.Validate(context.Background(), "country", "א", "אבג"); !errors.Is(err, boom) {
		t.Errorf("Validate() error = %v, want %v", err, boom)
	}
}
