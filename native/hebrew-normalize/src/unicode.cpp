#include "unicode.hpp"

#include <algorithm>
#include <cstddef>
#include <iterator>

namespace hebrew_normalize::detail {
namespace {

struct Decomposition {
  char32_t code_point;
  char32_t sequence[4];
  std::uint8_t length;
};

struct CombiningClass {
  char32_t code_point;
  std::uint8_t value;
};

struct LatinFold {
  char32_t code_point;
  char ascii;
};

// Defines kUnicodeDataVersion, kCanonical, kCompatibility, kCombiningClasses and kLatinFolds,
// each sorted by code point.
#include "unicode_tables.inc"

template <class Table>
const auto* lookup(const Table& table, char32_t cp) noexcept {
  const auto* first = std::begin(table);
  const auto* last = std::end(table);
  const auto* it =
      std::lower_bound(first, last, cp, [](const auto& entry, char32_t key) { return entry.code_point < key; });
  return (it != last && it->code_point == cp) ? it : nullptr;
}

std::span<const char32_t> sequence_of(const Decomposition* d) noexcept {
  if (d == nullptr) {
    return {};
  }
  return {d->sequence, static_cast<std::size_t>(d->length)};
}

}  // namespace

std::span<const char32_t> canonical_decomposition(char32_t cp) noexcept {
  return sequence_of(lookup(kCanonical, cp));
}

std::span<const char32_t> compatibility_decomposition(char32_t cp) noexcept {
  return sequence_of(lookup(kCompatibility, cp));
}

std::uint8_t combining_class(char32_t cp) noexcept {
  const auto* entry = lookup(kCombiningClasses, cp);
  return entry == nullptr ? std::uint8_t{0} : entry->value;
}

char latin_fold(char32_t cp) noexcept {
  const auto* entry = lookup(kLatinFolds, cp);
  return entry == nullptr ? '\0' : entry->ascii;
}

const char* unicode_data_version() noexcept { return kUnicodeDataVersion; }

}  // namespace hebrew_normalize::detail
