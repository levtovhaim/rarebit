/*
 * hebrew-normalize C API, for callers outside C++ (the Go validator calls it through cgo).
 *
 * Every function is pure and thread-safe, takes UTF-8, and never throws or aborts.
 * Output functions work like snprintf: they return the length of the full result in bytes
 * (without the terminating NUL), write at most out_cap - 1 bytes plus a NUL, and accept
 * out == NULL with out_cap == 0 to ask for the length. A return value >= out_cap means the
 * output was truncated (possibly in the middle of a UTF-8 character): call again with a buffer
 * of the returned length + 1.
 *
 * HN_ERROR (HN_MATCH_ERROR for matching) means an input was longer than HN_MAX_INPUT_BYTES,
 * an input was NULL with a non-zero length, or an allocation failed. On Linux an allocation
 * rarely fails visibly: the kernel ends the process first. That's why inputs are capped; the
 * caller should cap them too, before the call.
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

/* The longest input any function accepts, in bytes. Answers are a few words. */
#define HN_MAX_INPUT_BYTES 4096

typedef enum hn_match_kind {
  HN_MATCH_ERROR = -1,  /* an input over HN_MAX_INPUT_BYTES, NULL with a length, or no memory */
  HN_MATCH_NONE = 0,    /* not the same word */
  HN_MATCH_EXACT = 1,   /* same normalized form */
  HN_MATCH_VARIANT = 2, /* same word in full or defective spelling (ktiv male / haser) */
  HN_MATCH_FUZZY = 3    /* one edit apart (4+ letters): a likely typo */
} hn_match_kind;

/* Comparison key: no niqqud, final letters as regular ones, no spaces or punctuation, Latin
 * letters folded to lowercase ASCII, ASCII digits kept. Invalid UTF-8 is dropped. NFC and NFD
 * input give the same key. The key holds only Hebrew letters, a-z and 0-9. */
size_t hn_normalize(const char *in, size_t in_len, char *out, size_t out_cap);

/* Normalized form with the internal vav and yod letters that full spelling adds removed. */
size_t hn_spelling_key(const char *in, size_t in_len, char *out, size_t out_cap);

/* Unicode NFC / NFD for Hebrew text (U+0590-U+05FF, U+FB1D-U+FB4F); other code points pass
 * through unchanged, control characters and NULs included. Invalid UTF-8 becomes U+FFFD. */
size_t hn_to_nfc(const char *in, size_t in_len, char *out, size_t out_cap);
size_t hn_to_nfd(const char *in, size_t in_len, char *out, size_t out_cap);

/* How a player's answer relates to a word-list entry; both are normalized first. Callers
 * should find an exact match across all entries before accepting a variant or fuzzy one. */
hn_match_kind hn_match(const char *answer, size_t answer_len, const char *entry, size_t entry_len);

/* The same comparison for two keys that hn_normalize() already produced: normalize the answer
 * once, then compare it with many candidate keys without normalizing again. */
hn_match_kind hn_match_keys(const char *answer_key, size_t answer_key_len, const char *entry_key,
                            size_t entry_key_len);

/* Library version, and the Unicode version its tables were generated from. Static strings. */
const char *hn_version(void);
const char *hn_unicode_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HEBREW_NORMALIZE_H */
