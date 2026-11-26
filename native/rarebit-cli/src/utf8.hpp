// UTF-8 helpers for rarebit-cli, with the semantics of Go's unicode/utf8 where the validator's
// rules depend on them.
#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace rarebit::utf8 {

// Length in bytes of the valid UTF-8 sequence at the start of s, or nullopt if s doesn't start
// with one (an empty s, a stray continuation byte, an overlong form, a surrogate, past U+10FFFF).
[[nodiscard]] std::optional<std::size_t> sequence_length(std::string_view s) noexcept;

// Code points in s, counting every byte of an invalid sequence as one (Go's RuneCountInString).
[[nodiscard]] std::size_t rune_count(std::string_view s) noexcept;

// True when all of s is valid UTF-8.
[[nodiscard]] bool valid(std::string_view s) noexcept;

// Appends code point cp (at most U+10FFFF, not a surrogate) to out as UTF-8.
void append(std::string& out, char32_t cp);

}  // namespace rarebit::utf8
