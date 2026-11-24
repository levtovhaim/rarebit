// hebrew-normalize C++ API. The rules are described in hebrew_normalize.h and the README.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace hebrew_normalize {

enum class MatchKind { none, exact, variant, fuzzy };

// Comparison key: no niqqud, regular letters for final forms, no spaces or punctuation,
// Latin letters folded to lowercase ASCII, invalid UTF-8 dropped.
[[nodiscard]] std::string normalize(std::string_view utf8);

// normalize(), then the internal vav and yod letters of full spelling removed.
[[nodiscard]] std::string spelling_key(std::string_view utf8);

// Unicode NFC / NFD for Hebrew text; other code points pass through unchanged.
[[nodiscard]] std::string to_nfc(std::string_view utf8);
[[nodiscard]] std::string to_nfd(std::string_view utf8);

// How a player's answer relates to one word-list entry.
[[nodiscard]] MatchKind match(std::string_view answer, std::string_view entry);

// Levenshtein distance in code points.
[[nodiscard]] std::size_t edit_distance(std::string_view a_utf8, std::string_view b_utf8);

[[nodiscard]] std::string_view version() noexcept;
[[nodiscard]] std::string_view unicode_version() noexcept;

}  // namespace hebrew_normalize
