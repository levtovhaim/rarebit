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

// The lookups binary-search the tables and read `length` entries of `sequence`, so a hand-edited
// or broken .inc file must fail the build, not read out of bounds.
template <class Table>
constexpr bool strictly_sorted(const Table& table) {
  for (std::size_t i = 1; i < std::size(table); ++i) {
    if (!(table[i - 1].code_point < table[i].code_point)) {
      return false;
    }
  }
  return true;
}

template <class Table>
constexpr bool lengths_fit(const Table& table) {
  for (const Decomposition& d : table) {
    if (d.length == 0 || d.length > std::size(d.sequence)) {
      return false;
    }
  }
  return true;
}

static_assert(strictly_sorted(kCanonical) && lengths_fit(kCanonical), "kCanonical is malformed");
static_assert(strictly_sorted(kCompatibility) && lengths_fit(kCompatibility), "kCompatibility is malformed");
static_assert(strictly_sorted(kCombiningClasses), "kCombiningClasses is not sorted");
static_assert(strictly_sorted(kLatinFolds), "kLatinFolds is not sorted");

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
