// UTF-8 decoding and encoding (internal).
#pragma once

#include <string>
#include <string_view>

namespace hebrew_normalize::detail {

inline constexpr char32_t kReplacement = 0xFFFD;

// Each invalid byte (bad lead, bad or missing continuation, overlong form, surrogate, or a
// value above U+10FFFF) becomes one kReplacement.
[[nodiscard]] std::u32string decode_utf8(std::string_view in);

// Surrogates and values above U+10FFFF are written as kReplacement.
void append_utf8(std::string& out, char32_t cp);
[[nodiscard]] std::string encode_utf8(std::u32string_view in);

}  // namespace hebrew_normalize::detail
