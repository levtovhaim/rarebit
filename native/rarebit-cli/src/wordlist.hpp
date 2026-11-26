// The word lists (data/categories/<id>.json) and the validator's rules for one answer: the same
// steps and thresholds as apps/validator/internal/validate (exact key, spelling variant, one-edit
// typo), with each entry's keys computed as the validator's content load computes them.
#pragma once

#include <cstddef>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace rarebit::wordlist {

// The 22 letters a round can use (no final forms), as UTF-8.
inline constexpr std::string_view kLetters = "אבגדהוזחטיכלמנסעפצקרשת";

// The validator's defaults (VALIDATOR_MAX_ANSWER_RUNES, VALIDATOR_FUZZY_CANDIDATES) and the
// library's thresholds for a variant and a typo match, in letters of the key.
inline constexpr std::size_t kMaxAnswerRunes = 64;
inline constexpr std::size_t kFuzzyCandidates = 500;
inline constexpr std::size_t kMinVariantLetters = 3;
inline constexpr std::size_t kMinFuzzyLetters = 4;

struct Entry {
  std::string word;
  std::string key;           // normalize(word)
  std::string spelling_key;  // spelling_key(word); empty when the key has fewer than 3 letters
  std::string first_letter;  // the key's first letter
  std::size_t letters = 0;   // code points in the key
};

struct Category {
  std::string id;
  std::string name;
  std::string kind;
  std::vector<Entry> entries;  // sorted by word, byte order
};

// A category file that can't be read or doesn't follow data/README.md.
class DataError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

// What the caller asked for can't be answered: an unknown category or a letter that isn't one of
// the 22. The validator answers these with 400.
class RequestError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

// True for ids of the form ^[a-z][a-z0-9_-]{0,63}$ (the validator's CategoryID).
[[nodiscard]] bool valid_category_id(std::string_view id) noexcept;

// True when letter is exactly one of kLetters.
[[nodiscard]] bool valid_letter(std::string_view letter) noexcept;

// Reads dir/<id>.json. Throws RequestError for an id that can't exist or has no file, and
// DataError for a file that breaks the rules the validator's content load enforces.
[[nodiscard]] Category load(const std::filesystem::path& dir, std::string_view id);

// The keys of one entry, as the content load computes them. Throws DataError when the key
// doesn't start with one of the 22 letters.
[[nodiscard]] Entry keys(std::string_view word);

// The validator's answer to one request (its JSON fields; empty means omitted, except key).
struct Outcome {
  std::string result;  // valid, invalid, unknown
  std::string reason;  // invalid: too_long, empty, wrong_letter
  std::string match;   // valid: exact, variant, fuzzy
  std::string entry;   // valid: the entry that matched
  std::string key;     // the answer's comparison key
};

// Checks answer for letter in category. Throws RequestError for a letter that isn't one of the 22.
[[nodiscard]] Outcome check(const Category& category, std::string_view letter, std::string_view answer);

// outcome as the validator's JSON body: {"result":…,"reason":…,"match":…,"entry":…,"key":…},
// in that order, empty fields left out except key.
[[nodiscard]] std::string to_json(const Outcome& outcome);

}  // namespace rarebit::wordlist
