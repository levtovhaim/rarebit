// Package validate decides whether an answer is valid, invalid or unknown for a category and
// letter. It normalizes the answer once and looks it up in order: exact key, spelling variant,
// then a one-edit typo among a few candidates of similar length (native/hebrew-normalize README).
package validate

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/levtovhaim/rarebit/apps/validator/internal/hebrew"
)

// Result is what the game does with an answer.
type Result string

// Results. Unknown answers go to the room vote.
const (
	Valid   Result = "valid"
	Invalid Result = "invalid"
	Unknown Result = "unknown"
)

// Outcome is the answer to one validation request.
type Outcome struct {
	Result Result `json:"result"`
	Reason string `json:"reason,omitempty"` // for invalid: empty, too_long, wrong_letter
	Match  string `json:"match,omitempty"`  // for valid: exact, variant, fuzzy
	Entry  string `json:"entry,omitempty"`  // for valid: the word-list entry that matched
	Key    string `json:"key"`              // the answer's comparison key
}

// Category is one the game can play: a live category and the round letters that have enough
// entries in it (MinLetterWords) for a fair round.
type Category struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Kind    string   `json:"kind"`
	Letters []string `json:"letters"`
}

// MinLetterWords is how many entries a letter needs in a category before rounds use it: the
// same threshold as THIN in data/tools/check_data.py.
const MinLetterWords = 3

// Candidate is a word-list entry considered for a typo match.
type Candidate struct {
	Word string
	Key  string
}

// Store is the word-list lookup the validator needs.
type Store interface {
	CategoryExists(ctx context.Context, category string) (bool, error)
	FindByKey(ctx context.Context, category, key string) (word string, found bool, err error)
	FindBySpellingKey(ctx context.Context, category, spellingKey string) (word string, found bool, err error)
	FuzzyCandidates(ctx context.Context, category, firstLetter string, minLen, maxLen, limit int) ([]Candidate, error)
}

// Request errors: the caller sent something the game should never send.
var (
	ErrUnknownCategory = errors.New("unknown category")
	ErrBadLetter       = errors.New("letter must be one Hebrew letter, not a final form")
)

// Letters are the 22 letters a round can use.
const Letters = "אבגדהוזחטיכלמנסעפצקרשת"

// CategoryID is the form of a category id, here, in the data files and in the schema's CHECK.
var CategoryID = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,63}$`)

// Minimum key lengths, in letters, for a variant and a typo match (the library's thresholds).
const (
	minVariantLetters = 3
	minFuzzyLetters   = 4
)

// Validator answers validation requests against a Store.
type Validator struct {
	store           Store
	maxRunes        int
	fuzzyCandidates int
}

// New returns a Validator. maxRunes caps the answer length; fuzzyCandidates caps the typo search.
func New(store Store, maxRunes, fuzzyCandidates int) *Validator {
	return &Validator{store: store, maxRunes: maxRunes, fuzzyCandidates: fuzzyCandidates}
}

// Validate checks one answer.
func (v *Validator) Validate(ctx context.Context, category, letter, answer string) (Outcome, error) {
	if utf8.RuneCountInString(letter) != 1 || !strings.Contains(Letters, letter) {
		return Outcome{}, ErrBadLetter
	}
	if !CategoryID.MatchString(category) { // no query for ids that can't exist (a NUL fails in Postgres)
		return Outcome{}, ErrUnknownCategory
	}
	ok, err := v.store.CategoryExists(ctx, category)
	if err != nil {
		return Outcome{}, err
	}
	if !ok {
		return Outcome{}, ErrUnknownCategory
	}
	if utf8.RuneCountInString(answer) > v.maxRunes {
		return Outcome{Result: Invalid, Reason: "too_long"}, nil
	}

	key, err := hebrew.Normalize(answer)
	if err != nil {
		return Outcome{Result: Invalid, Reason: "too_long"}, nil
	}
	if key == "" {
		return Outcome{Result: Invalid, Reason: "empty", Key: key}, nil
	}
	first, _ := utf8.DecodeRuneInString(key)
	if string(first) != letter {
		return Outcome{Result: Invalid, Reason: "wrong_letter", Key: key}, nil
	}

	if word, found, err := v.store.FindByKey(ctx, category, key); err != nil || found {
		return valid(word, "exact", key), err
	}
	letters := utf8.RuneCountInString(key)
	if letters >= minVariantLetters {
		spelling, err := hebrew.SpellingKey(answer)
		if err != nil {
			return Outcome{}, err
		}
		if word, found, err := v.store.FindBySpellingKey(ctx, category, spelling); err != nil || found {
			return valid(word, "variant", key), err
		}
	}
	if letters >= minFuzzyLetters {
		candidates, err := v.store.FuzzyCandidates(ctx, category, letter, letters-1, letters+1, v.fuzzyCandidates)
		if err != nil {
			return Outcome{}, err
		}
		for _, c := range candidates {
			kind, err := hebrew.MatchKeys(key, c.Key)
			if err != nil {
				return Outcome{}, err
			}
			if kind == hebrew.Fuzzy {
				return valid(c.Word, "fuzzy", key), nil
			}
		}
	}
	return Outcome{Result: Unknown, Key: key}, nil
}

func valid(word, match, key string) Outcome {
	return Outcome{Result: Valid, Match: match, Entry: word, Key: key}
}
