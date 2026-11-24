// Code-point level building blocks shared by the implementation files and the tests (internal).
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace hebrew_normalize::detail {

inline constexpr char32_t kVav = 0x05D5;
inline constexpr char32_t kYod = 0x05D9;

// A variant (full vs defective spelling) needs 3+ letters; a fuzzy match needs 4+ letters.
inline constexpr std::size_t kMinVariantLength = 3;
inline constexpr std::size_t kMinFuzzyLength = 4;

[[nodiscard]] std::u32string normalize_cp(std::string_view utf8);
[[nodiscard]] std::u32string spelling_key_cp(std::u32string_view normalized);
[[nodiscard]] std::u32string to_nfd_cp(std::string_view utf8);

[[nodiscard]] std::size_t edit_distance_cp(std::u32string_view a, std::u32string_view b);
// edit_distance_cp(a, b) <= 1, in linear time.
[[nodiscard]] bool within_one_edit(std::u32string_view a, std::u32string_view b) noexcept;

}  // namespace hebrew_normalize::detail
