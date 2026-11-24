#include <algorithm>
#include <cstddef>
#include <utility>
#include <vector>

#include "hebrew_normalize/hebrew_normalize.hpp"
#include "internal.hpp"
#include "utf8.hpp"

namespace hebrew_normalize {
namespace detail {

std::size_t edit_distance_cp(std::u32string_view a, std::u32string_view b) {
  if (a.size() < b.size()) {
    std::swap(a, b);  // one row over the shorter string
  }
  std::vector<std::size_t> row(b.size() + 1);
  for (std::size_t j = 0; j <= b.size(); ++j) {
    row[j] = j;
  }
  for (std::size_t i = 1; i <= a.size(); ++i) {
    std::size_t diagonal = row[0];
    row[0] = i;
    for (std::size_t j = 1; j <= b.size(); ++j) {
      const std::size_t above = row[j];
      const std::size_t cost = (a[i - 1] == b[j - 1]) ? 0 : 1;
      row[j] = std::min({above + 1, row[j - 1] + 1, diagonal + cost});
      diagonal = above;
    }
  }
  return row[b.size()];
}

bool within_one_edit(std::u32string_view a, std::u32string_view b) noexcept {
  if (a.size() > b.size()) {
    std::swap(a, b);
  }
  if (b.size() - a.size() > 1) {
    return false;
  }
  std::size_t i = 0;
  while (i < a.size() && a[i] == b[i]) {
    ++i;
  }
  if (i == a.size()) {
    return true;  // equal, or one letter added at the end
  }
  if (a.size() == b.size()) {
    return a.substr(i + 1) == b.substr(i + 1);  // one substitution
  }
  return a.substr(i) == b.substr(i + 1);  // one insertion
}

}  // namespace detail

std::size_t edit_distance(std::string_view a_utf8, std::string_view b_utf8) {
  return detail::edit_distance_cp(detail::decode_utf8(a_utf8), detail::decode_utf8(b_utf8));
}

namespace detail {

MatchKind match_cp(std::u32string_view a, std::u32string_view e) {
  if (a.empty() || e.empty()) {
    return MatchKind::none;
  }
  if (a == e) {
    return MatchKind::exact;
  }
  if (a.size() >= kMinVariantLength && e.size() >= kMinVariantLength && spelling_key_cp(a) == spelling_key_cp(e)) {
    return MatchKind::variant;
  }
  if (a.size() >= kMinFuzzyLength && e.size() >= kMinFuzzyLength && within_one_edit(a, e)) {
    return MatchKind::fuzzy;
  }
  return MatchKind::none;
}

}  // namespace detail

MatchKind match(std::string_view answer, std::string_view entry) {
  return detail::match_cp(detail::normalize_cp(answer), detail::normalize_cp(entry));
}

MatchKind match_keys(std::string_view answer_key, std::string_view entry_key) {
  return detail::match_cp(detail::decode_utf8(answer_key), detail::decode_utf8(entry_key));
}

}  // namespace hebrew_normalize
