package migrate

import (
	"strings"
	"testing"
	"testing/fstest"
)

func TestEmbedded(t *testing.T) {
	ms, err := Embedded()
	if err != nil {
		t.Fatal(err)
	}
	if len(ms) == 0 || ms[0].Version != 1 || ms[0].Checksum == "" {
		t.Errorf("Embedded() = %+v, want migration 1 first, with a checksum", ms)
	}
}

func TestParseRejects(t *testing.T) {
	tests := []struct {
		name    string
		files   []string
		wantErr string
	}{
		{"bad name", []string{"0001_ok.sql", "2_short.sql"}, "NNNN_name.sql"},
		{"gap", []string{"0001_a.sql", "0003_c.sql"}, "without gaps"},
		{"not starting at 1", []string{"0002_b.sql"}, "without gaps"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fsys := fstest.MapFS{}
			for _, f := range tt.files {
				fsys["m/"+f] = &fstest.MapFile{Data: []byte("SELECT 1;")}
			}
			_, err := parse(fsys, "m")
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("parse() error = %v, want it to mention %q", err, tt.wantErr)
			}
		})
	}
}
