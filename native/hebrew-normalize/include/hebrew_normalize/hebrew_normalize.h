/*
 * hebrew-normalize C API, for callers outside C++ (the Go validator calls it through cgo).
 *
 * Every function is pure and thread-safe, takes UTF-8 and never throws or aborts.
 * Output functions work like snprintf: they return the length of the full result in bytes
 * (without the terminating NUL), write at most out_cap - 1 bytes plus a NUL, and accept
 * out == NULL with out_cap == 0 to ask for the length. A return value >= out_cap means the
 * output was truncated. HN_ERROR means memory ran out, or `in` was NULL with in_len > 0.
 */
#ifndef HEBREW_NORMALIZE_H
#define HEBREW_NORMALIZE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
#define HN_ERROR (static_cast<size_t>(-1))
#else
#define HN_ERROR ((size_t)-1)
#endif

typedef enum hn_match_kind {
  HN_MATCH_ERROR = -1,  /* memory ran out, or a NULL input with a non-zero length */
  HN_MATCH_NONE = 0,    /* not the same word */
  HN_MATCH_EXACT = 1,   /* same normalized form */
  HN_MATCH_VARIANT = 2, /* same word in full or defective spelling (ktiv male / haser) */
  HN_MATCH_FUZZY = 3    /* one edit apart (4+ letters): a likely typo */
} hn_match_kind;

/* Comparison key: no niqqud, final letters as regular ones, no spaces or punctuation, Latin
 * letters folded to lowercase ASCII. Invalid UTF-8 is dropped. NFC and NFD input give the same key. */
size_t hn_normalize(const char *in, size_t in_len, char *out, size_t out_cap);

/* Normalized form with the internal vav and yod letters that full spelling adds removed. */
size_t hn_spelling_key(const char *in, size_t in_len, char *out, size_t out_cap);

/* Unicode NFC / NFD for Hebrew text (U+0590-U+05FF, U+FB1D-U+FB4F); other code points pass
 * through unchanged. Invalid UTF-8 becomes U+FFFD. */
size_t hn_to_nfc(const char *in, size_t in_len, char *out, size_t out_cap);
size_t hn_to_nfd(const char *in, size_t in_len, char *out, size_t out_cap);

/* How a player's answer relates to a word-list entry. Callers should look for an exact
 * match across all entries before accepting a variant or fuzzy one. */
hn_match_kind hn_match(const char *answer, size_t answer_len, const char *entry, size_t entry_len);

/* Library version, and the Unicode version its tables were generated from. Static strings. */
const char *hn_version(void);
const char *hn_unicode_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HEBREW_NORMALIZE_H */
