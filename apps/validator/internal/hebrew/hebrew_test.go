package hebrew

import (
	"errors"
	"strings"
	"testing"
)

func TestNormalize(t *testing.T) {
	tests := []struct {
		name, in, want string
	}{
		{"niqqud and final letters", "שָׁלוֹם", "שלומ"},
		{"spaces and punctuation", "תל־אביב, יפו!", "תלאביביפו"},
		{"latin and digits", "iPhone 15", "iphone15"},
		{"empty", "", ""},
		{"punctuation only", "?!", ""},
		{"invalid utf-8 dropped", "א\xffב", "אב"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Normalize(tt.in)
			if err != nil {
				t.Fatalf("Normalize(%q) error: %v", tt.in, err)
			}
			if got != tt.want {
				t.Errorf("Normalize(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestSpellingKey(t *testing.T) {
	a, err := SpellingKey("שולחן")
	if err != nil {
		t.Fatal(err)
	}
	b, err := SpellingKey("שלחן")
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Errorf("SpellingKey: %q vs %q, want equal", a, b)
	}
}

func TestMatchKeys(t *testing.T) {
	tests := []struct {
		answer, entry string
		want          MatchKind
	}{
		{"ישראל", "יִשְׂרָאֵל", Exact},
		{"שלחן", "שולחן", Variant},
		{"פאריז", "פריז", Fuzzy},
		{"ים", "יום", None},
		{"", "ירושלים", None},
	}
	for _, tt := range tests {
		t.Run(tt.answer+"/"+tt.entry, func(t *testing.T) {
			a, _ := Normalize(tt.answer)
			e, _ := Normalize(tt.entry)
			got, err := MatchKeys(a, e)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("MatchKeys(%q, %q) = %v, want %v", a, e, got, tt.want)
			}
		})
	}
}

func TestInputsOverTheCapAreRejected(t *testing.T) {
	long := strings.Repeat("א", MaxInputBytes) // 2 bytes per letter: twice the cap
	if _, err := Normalize(long); !errors.Is(err, ErrInput) {
		t.Errorf("Normalize(long) error = %v, want ErrInput", err)
	}
	if _, err := MatchKeys(long, "א"); !errors.Is(err, ErrInput) {
		t.Errorf("MatchKeys(long) error = %v, want ErrInput", err)
	}
	atCap := strings.Repeat("a", MaxInputBytes)
	got, err := Normalize(atCap)
	if err != nil || got != atCap {
		t.Errorf("Normalize(at cap) = %d bytes, %v; want the input back", len(got), err)
	}
}

func TestVersions(t *testing.T) {
	if Version() == "" || UnicodeVersion() == "" {
		t.Errorf("Version() = %q, UnicodeVersion() = %q, want non-empty", Version(), UnicodeVersion())
	}
}
