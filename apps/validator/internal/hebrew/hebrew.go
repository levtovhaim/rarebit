// Package hebrew calls native/hebrew-normalize through cgo.
//
// The archive and headers come from an install prefix of the library: build with
// CGO_CFLAGS=-I<prefix>/include and CGO_LDFLAGS=-L<prefix>/lib (`make validator` sets both).
// The wrapper follows the library's C contract (native/hebrew-normalize/README.md): inputs are
// capped before the call, an empty input is passed as NULL with length 0, results are read with
// the returned length, and a truncated result is fetched again with an exact-size buffer.
package hebrew

/*
#cgo LDFLAGS: -lhebrew_normalize -lstdc++ -lm
#include <stddef.h>
#include <hebrew_normalize/hebrew_normalize.h>

// cgo can't see a macro cast to size_t, and can't link to a static variable: a function works.
static inline size_t hn_error_value(void) { return HN_ERROR; }
*/
import "C"

import (
	"errors"
	"unsafe"
)

var hnError = C.hn_error_value()

// MaxInputBytes is the longest input the library accepts.
const MaxInputBytes = int(C.HN_MAX_INPUT_BYTES)

// ErrInput means the library rejected an input: longer than MaxInputBytes, or out of memory.
var ErrInput = errors.New("hebrew: input rejected")

// MatchKind is how an answer key relates to an entry key.
type MatchKind int

// The match kinds, in the library's order.
const (
	None MatchKind = iota
	Exact
	Variant
	Fuzzy
)

func (k MatchKind) String() string {
	switch k {
	case Exact:
		return "exact"
	case Variant:
		return "variant"
	case Fuzzy:
		return "fuzzy"
	default:
		return "none"
	}
}

type cFunc func(in *C.char, inLen C.size_t, out *C.char, outCap C.size_t) C.size_t

// cString points C at the bytes of s without copying. C only reads them during the call.
func cString(s string) (*C.char, C.size_t) {
	if len(s) == 0 {
		return nil, 0
	}
	return (*C.char)(unsafe.Pointer(unsafe.StringData(s))), C.size_t(len(s))
}

func transform(s string, f cFunc) (string, error) {
	if len(s) > MaxInputBytes {
		return "", ErrInput
	}
	in, inLen := cString(s)
	// normalize() returns at most 2x the input bytes and to_nfd() 3x: this fits nearly always.
	buf := make([]byte, 3*len(s)+16)
	n := f(in, inLen, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
	if n == hnError {
		return "", ErrInput
	}
	if int(n) >= len(buf) {
		buf = make([]byte, int(n)+1)
		n = f(in, inLen, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
		if n == hnError || int(n) >= len(buf) {
			return "", ErrInput
		}
	}
	return string(buf[:n]), nil
}

// Normalize returns the comparison key of an answer or a word-list entry: Hebrew letters,
// a-z and 0-9 only. An empty key means there was nothing usable in the input.
func Normalize(s string) (string, error) {
	return transform(s, func(in *C.char, inLen C.size_t, out *C.char, outCap C.size_t) C.size_t {
		return C.hn_normalize(in, inLen, out, outCap)
	})
}

// SpellingKey returns the key with the vav and yod letters of full spelling removed.
func SpellingKey(s string) (string, error) {
	return transform(s, func(in *C.char, inLen C.size_t, out *C.char, outCap C.size_t) C.size_t {
		return C.hn_spelling_key(in, inLen, out, outCap)
	})
}

// MatchKeys compares two keys that Normalize produced.
func MatchKeys(answerKey, entryKey string) (MatchKind, error) {
	if len(answerKey) > MaxInputBytes || len(entryKey) > MaxInputBytes {
		return None, ErrInput
	}
	a, aLen := cString(answerKey)
	e, eLen := cString(entryKey)
	switch C.hn_match_keys(a, aLen, e, eLen) {
	case C.HN_MATCH_EXACT:
		return Exact, nil
	case C.HN_MATCH_VARIANT:
		return Variant, nil
	case C.HN_MATCH_FUZZY:
		return Fuzzy, nil
	case C.HN_MATCH_NONE:
		return None, nil
	default:
		return None, ErrInput
	}
}

// Version is the library version; UnicodeVersion is the Unicode version of its tables.
func Version() string { return C.GoString(C.hn_version()) }

// UnicodeVersion is the Unicode version the library's tables were generated from.
func UnicodeVersion() string { return C.GoString(C.hn_unicode_version()) }
