// Lookups into the generated Unicode tables (internal). See tools/gen_unicode_data.py.
#pragma once

#include <cstdint>
#include <span>

namespace hebrew_normalize::detail {

// The Hebrew block and the Hebrew presentation forms: the code points the tables cover.
constexpr bool in_hebrew_scope(char32_t cp) noexcept {
  return (cp >= 0x0590U && cp <= 0x05FFU) || (cp >= 0xFB1DU && cp <= 0xFB4FU);
}

// Full canonical decomposition (NFD of one code point); empty when it has none.
[[nodiscard]] std::span<const char32_t> canonical_decomposition(char32_t cp) noexcept;

// Full compatibility decomposition (NFKD of one code point); empty when it has none.
[[nodiscard]] std::span<const char32_t> compatibility_decomposition(char32_t cp) noexcept;

// Canonical combining class; 0 for code points outside the tables.
[[nodiscard]] std::uint8_t combining_class(char32_t cp) noexcept;

// Lowercase ASCII base letter of a Latin-1 Supplement or Latin Extended-A letter; '\0' if none.
[[nodiscard]] char latin_fold(char32_t cp) noexcept;

[[nodiscard]] const char* unicode_data_version() noexcept;

}  // namespace hebrew_normalize::detail
