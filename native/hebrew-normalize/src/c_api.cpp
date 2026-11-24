// The C API: thin wrappers that never let a C++ exception cross the boundary.
#include "hebrew_normalize/hebrew_normalize.h"

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <string>
#include <string_view>

#include "hebrew_normalize/hebrew_normalize.hpp"
#include "unicode.hpp"

namespace {

bool bad_input(const char* in, std::size_t len) noexcept { return in == nullptr && len > 0; }

std::string_view view_of(const char* in, std::size_t len) noexcept {
  return len == 0 ? std::string_view{} : std::string_view{in, len};
}

std::size_t copy_out(const std::string& s, char* out, std::size_t out_cap) noexcept {
  if (out != nullptr && out_cap > 0) {
    const std::size_t n = std::min(s.size(), out_cap - 1);
    std::memcpy(out, s.data(), n);
    out[n] = '\0';
  }
  return s.size();
}

template <class Transform>
std::size_t transform_into(const char* in, std::size_t in_len, char* out, std::size_t out_cap, Transform transform) noexcept {
  if (bad_input(in, in_len)) {
    return HN_ERROR;
  }
  try {
    return copy_out(transform(view_of(in, in_len)), out, out_cap);
  } catch (...) {
    return HN_ERROR;
  }
}

}  // namespace

extern "C" {

size_t hn_normalize(const char* in, size_t in_len, char* out, size_t out_cap) {
  return transform_into(in, in_len, out, out_cap, [](std::string_view s) { return hebrew_normalize::normalize(s); });
}

size_t hn_spelling_key(const char* in, size_t in_len, char* out, size_t out_cap) {
  return transform_into(in, in_len, out, out_cap, [](std::string_view s) { return hebrew_normalize::spelling_key(s); });
}

size_t hn_to_nfc(const char* in, size_t in_len, char* out, size_t out_cap) {
  return transform_into(in, in_len, out, out_cap, [](std::string_view s) { return hebrew_normalize::to_nfc(s); });
}

size_t hn_to_nfd(const char* in, size_t in_len, char* out, size_t out_cap) {
  return transform_into(in, in_len, out, out_cap, [](std::string_view s) { return hebrew_normalize::to_nfd(s); });
}

hn_match_kind hn_match(const char* answer, size_t answer_len, const char* entry, size_t entry_len) {
  if (bad_input(answer, answer_len) || bad_input(entry, entry_len)) {
    return HN_MATCH_ERROR;
  }
  try {
    switch (hebrew_normalize::match(view_of(answer, answer_len), view_of(entry, entry_len))) {
      case hebrew_normalize::MatchKind::exact:
        return HN_MATCH_EXACT;
      case hebrew_normalize::MatchKind::variant:
        return HN_MATCH_VARIANT;
      case hebrew_normalize::MatchKind::fuzzy:
        return HN_MATCH_FUZZY;
      case hebrew_normalize::MatchKind::none:
        return HN_MATCH_NONE;
    }
    return HN_MATCH_NONE;
  } catch (...) {
    return HN_MATCH_ERROR;
  }
}

const char* hn_version(void) { return HN_VERSION; }

const char* hn_unicode_version(void) { return hebrew_normalize::detail::unicode_data_version(); }

}  // extern "C"
