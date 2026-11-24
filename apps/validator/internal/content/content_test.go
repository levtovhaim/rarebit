package content

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeCategory(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "categories"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "categories", name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

const good = `{"id": "animal", "name": "חי", "kind": "regular",
  "lists": [{"source": "s", "license": "MIT", "words": ["אריה", "פיל", "תן"]}]}`

func TestReadTheRepoData(t *testing.T) {
	set, err := Read(filepath.Join("..", "..", "..", "..", "data"))
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Categories) < 6 || set.Words < 1000 {
		t.Errorf("Read(data) = %d categories, %d words; want the seeded lists", len(set.Categories), set.Words)
	}
}

func TestReadIsDeterministic(t *testing.T) {
	dir := t.TempDir()
	writeCategory(t, dir, "animal.json", good)
	a, err := Read(dir)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := Read(dir)
	if a.SHA256 != b.SHA256 || a.Words != 3 {
		t.Errorf("Read() = %s/%d then %s, want the same hash and 3 words", a.SHA256, a.Words, b.SHA256)
	}
	writeCategory(t, dir, "animal.json", strings.Replace(good, "פיל", "פילון", 1))
	c, _ := Read(dir)
	if c.SHA256 == a.SHA256 {
		t.Error("changing a word didn't change the hash")
	}
}

func TestReadRejects(t *testing.T) {
	tests := []struct {
		name, file, body, wantErr string
	}{
		{"id differs from file name", "plant.json", good, "must match the file name"},
		{"unknown key", "animal.json", strings.Replace(good, `"kind"`, `"extra": 1, "kind"`, 1), "unknown field"},
		{"bad kind", "animal.json", strings.Replace(good, "regular", "odd", 1), "kind"},
		{"duplicate word", "animal.json", strings.Replace(good, `"תן"`, `"פיל"`, 1), "appears twice"},
		{"word with no letters", "animal.json", strings.Replace(good, `"תן"`, `"--"`, 1), "round letters"},
		{"latin word", "animal.json", strings.Replace(good, `"תן"`, `"cat"`, 1), "round letters"},
		{"no license", "animal.json", strings.Replace(good, `"MIT"`, `""`, 1), "license"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			writeCategory(t, dir, tt.file, tt.body)
			_, err := Read(dir)
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("Read() error = %v, want it to mention %q", err, tt.wantErr)
			}
		})
	}
}

func TestReadNeedsFiles(t *testing.T) {
	if _, err := Read(t.TempDir()); err == nil {
		t.Error("Read(empty dir) succeeded, want an error")
	}
}

func TestKeys(t *testing.T) {
	tests := []struct {
		word string
		want Word
	}{
		{"שולחן", Word{Word: "שולחן", Key: "שולחנ", SpellingKey: "שלחנ", FirstLetter: "ש", Letters: 5}},
		{"תן", Word{Word: "תן", Key: "תנ", FirstLetter: "ת", Letters: 2}},
		{"תל אביב", Word{Word: "תל אביב", Key: "תלאביב", SpellingKey: "תלאבב", FirstLetter: "ת", Letters: 6}},
	}
	for _, tt := range tests {
		t.Run(tt.word, func(t *testing.T) {
			got, err := Keys(tt.word)
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Errorf("Keys(%q) = %+v, want %+v", tt.word, got, tt.want)
			}
		})
	}
}
