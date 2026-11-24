#include <algorithm>
#include <cstddef>
#include <span>

#include "hebrew_normalize/hebrew_normalize.hpp"
#include "internal.hpp"
#include "unicode.hpp"
#include "utf8.hpp"

namespace hebrew_normalize {
namespace detail {
namespace {

constexpr char32_t kAlef = 0x05D0;
constexpr char32_t kTav = 0x05EA;

// Final letters (sofit) compare as their regular forms: ך→כ ם→מ ן→נ ף→פ ץ→צ.
constexpr char32_t regular_form(char32_t cp) noexcept {
  switch (cp) {
    case 0x05DA:
      return 0x05DB;
    case 0x05DD:
      return 0x05DE;
    case 0x05DF:
      return 0x05E0;
    case 0x05E3:
      return 0x05E4;
    case 0x05E5:
      return 0x05E6;
    default:
      return cp;
  }
}

// Keeps a Hebrew letter; drops points, cantillation marks and Hebrew punctuation.
void keep_letter(std::u32string& out, char32_t cp) {
  if (cp >= kAlef && cp <= kTav) {
    out.push_back(regular_form(cp));
  }
}

// One Hebrew code point that has no further decomposition.
void append_hebrew_base(std::u32string& out, char32_t cp) {
  // The Yiddish ligatures have no Unicode decomposition, so they're spelled out here. They
  // also appear inside decompositions: U+FB1F is U+05F2 with a patah.
  switch (cp) {
    case 0x05F0:
      out.push_back(kVav);
      out.push_back(kVav);
      return;
    case 0x05F1:
      out.push_back(kVav);
      out.push_back(kYod);
      return;
    case 0x05F2:
      out.push_back(kYod);
      out.push_back(kYod);
      return;
    default:
      keep_letter(out, cp);
      return;
  }
}

void append_hebrew(std::u32string& out, char32_t cp) {
  // NFKD: presentation forms (with or without points) and wide letters become plain letters.
  const std::span<const char32_t> parts = compatibility_decomposition(cp);
  if (parts.empty()) {
    append_hebrew_base(out, cp);
    return;
  }
  for (const char32_t part : parts) {
    append_hebrew_base(out, part);
  }
}

void append_other(std::u32string& out, char32_t cp) {
  if ((cp >= U'a' && cp <= U'z') || (cp >= U'0' && cp <= U'9')) {
    out.push_back(cp);
    return;
  }
  if (cp >= U'A' && cp <= U'Z') {
    out.push_back(static_cast<char32_t>(cp + (U'a' - U'A')));
    return;
  }
  const char folded = latin_fold(cp);
  if (folded != '\0') {
    out.push_back(static_cast<char32_t>(static_cast<unsigned char>(folded)));
  }
  // Everything else is dropped: spaces, punctuation, combining marks, other scripts.
}

// Canonical ordering: a run of combining marks is sorted (stably) by combining class.
void canonical_order(std::u32string& s) {
  std::size_t i = 0;
  while (i < s.size()) {
    if (combining_class(s[i]) == 0) {
      ++i;
      continue;
    }
    std::size_t j = i;
    while (j < s.size() && combining_class(s[j]) != 0) {
      ++j;
    }
    std::stable_sort(s.begin() + static_cast<std::ptrdiff_t>(i), s.begin() + static_cast<std::ptrdiff_t>(j),
                     [](char32_t a, char32_t b) { return combining_class(a) < combining_class(b); });
    i = j;
  }
}

}  // namespace

std::u32string normalize_cp(std::string_view utf8) {
  std::u32string out;
  for (const char32_t cp : decode_utf8(utf8)) {
    if (in_hebrew_scope(cp)) {
      append_hebrew(out, cp);
    } else {
      append_other(out, cp);
    }
  }
  return out;
}

// Full spelling (ktiv male) adds vav and yod as vowel letters: שולחן vs שלחן, תוכנית vs תכנית.
// The key collapses doubled vav/yod and drops the ones between the first and the last letter.
// It is a heuristic: callers compare keys only after an exact match failed.
std::u32string spelling_key_cp(std::u32string_view normalized) {
  std::u32string collapsed;
  collapsed.reserve(normalized.size());
  for (const char32_t cp : normalized) {
    const bool doubled = (cp == kVav || cp == kYod) && !collapsed.empty() && collapsed.back() == cp;
    if (!doubled) {
      collapsed.push_back(cp);
    }
  }
  if (collapsed.size() <= 2) {
    return collapsed;
  }
  std::u32string key;
  key.reserve(collapsed.size());
  key.push_back(collapsed.front());
  for (std::size_t i = 1; i + 1 < collapsed.size(); ++i) {
    if (collapsed[i] != kVav && collapsed[i] != kYod) {
      key.push_back(collapsed[i]);
    }
  }
  key.push_back(collapsed.back());
  return key;
}

std::u32string to_nfd_cp(std::string_view utf8) {
  std::u32string out;
  for (const char32_t cp : decode_utf8(utf8)) {
    const std::span<const char32_t> parts =
        in_hebrew_scope(cp) ? canonical_decomposition(cp) : std::span<const char32_t>{};
    if (parts.empty()) {
      out.push_back(cp);
    } else {
      out.append(parts.begin(), parts.end());
    }
  }
  canonical_order(out);
  return out;
}

}  // namespace detail

std::string normalize(std::string_view utf8) { return detail::encode_utf8(detail::normalize_cp(utf8)); }

std::string spelling_key(std::string_view utf8) {
  return detail::encode_utf8(detail::spelling_key_cp(detail::normalize_cp(utf8)));
}

std::string to_nfd(std::string_view utf8) { return detail::encode_utf8(detail::to_nfd_cp(utf8)); }

// Every Hebrew character with a canonical decomposition (U+FB1D-U+FB4E) is a Unicode
// composition exclusion, so NFC never recomposes Hebrew: within this library's scope NFC
// equals NFD. The generator asserts that, and tests/data/unicode_vectors.tsv checks both
// forms against Python's unicodedata.
std::string to_nfc(std::string_view utf8) { return to_nfd(utf8); }

std::string_view version() noexcept { return HN_VERSION; }

std::string_view unicode_version() noexcept { return detail::unicode_data_version(); }

}  // namespace hebrew_normalize
