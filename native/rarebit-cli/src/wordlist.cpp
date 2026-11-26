#include "wordlist.hpp"

#include <algorithm>
#include <fstream>
#include <initializer_list>
#include <iterator>
#include <set>

#include <hebrew_normalize/hebrew_normalize.hpp>

#include "json.hpp"
#include "utf8.hpp"

namespace rarebit::wordlist {

namespace hn = hebrew_normalize;

namespace {

constexpr std::size_t kLetterBytes = 2;  // every Hebrew letter is two bytes in UTF-8

// The member's string value; throws DataError when it's missing or not a string.
const std::string& string_member(const json::Object& object, std::string_view name, const std::string& where) {
  const json::Value* v = json::find(object, name);
  if (v == nullptr || v->string() == nullptr) {
    throw DataError(where + ": \"" + std::string(name) + "\" must be a string");
  }
  return *v->string();
}

// Throws DataError for any member not in allowed (the content load's DisallowUnknownFields).
void only_members(const json::Object& object, std::initializer_list<std::string_view> allowed,
                  const std::string& where) {
  for (const auto& member : object) {
    if (std::find(allowed.begin(), allowed.end(), member.first) == allowed.end()) {
      throw DataError(where + ": unknown field \"" + member.first + "\"");
    }
  }
}

std::string read_file(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    throw DataError("can't read " + path.string());
  }
  return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

Outcome valid(const std::string& word, std::string match, std::string key) {
  return Outcome{"valid", "", std::move(match), word, std::move(key)};
}

}  // namespace

bool valid_category_id(std::string_view id) noexcept {
  if (id.empty() || id.size() > 64 || id.front() < 'a' || id.front() > 'z') {
    return false;
  }
  return std::all_of(id.begin(), id.end(), [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
  });
}

bool valid_letter(std::string_view letter) noexcept {
  if (letter.size() != kLetterBytes) {
    return false;
  }
  for (std::size_t i = 0; i < kLetters.size(); i += kLetterBytes) {
    if (kLetters.substr(i, kLetterBytes) == letter) {
      return true;
    }
  }
  return false;
}

Entry keys(std::string_view word) {
  Entry e;
  e.word = std::string(word);
  e.key = hn::normalize(word);
  if (e.key.size() < kLetterBytes || !valid_letter(std::string_view(e.key).substr(0, kLetterBytes))) {
    throw DataError("\"" + e.word + "\": its key must start with one of the 22 round letters");
  }
  e.first_letter = e.key.substr(0, kLetterBytes);
  e.letters = utf8::rune_count(e.key);
  if (e.letters >= kMinVariantLetters) {
    e.spelling_key = hn::spelling_key(word);
  }
  return e;
}

Category load(const std::filesystem::path& dir, std::string_view id) {
  if (!valid_category_id(id)) {
    throw RequestError("unknown category");
  }
  const std::filesystem::path path = dir / (std::string(id) + ".json");
  std::error_code ec;
  if (!std::filesystem::is_regular_file(path, ec)) {
    throw RequestError("unknown category");
  }
  const std::string where = path.string();
  json::Value root;
  try {
    root = json::parse(read_file(path));
  } catch (const json::ParseError& e) {
    throw DataError(where + ": " + e.what());
  }
  const json::Object* top = root.object();
  if (top == nullptr) {
    throw DataError(where + ": must be a JSON object");
  }
  only_members(*top, {"id", "name", "kind", "lists"}, where);

  Category c;
  c.id = string_member(*top, "id", where);
  c.name = string_member(*top, "name", where);
  c.kind = string_member(*top, "kind", where);
  if (c.id != id) {
    throw DataError(where + ": id \"" + c.id + "\" must match the file name");
  }
  if (c.name.empty()) {
    throw DataError(where + ": name is empty");
  }
  if (c.kind != "regular" && c.kind != "creative") {
    throw DataError(where + ": kind \"" + c.kind + "\" must be regular or creative");
  }
  const json::Value* lists = json::find(*top, "lists");
  if (lists == nullptr || lists->array() == nullptr || lists->array()->empty()) {
    throw DataError(where + ": no lists");
  }

  std::set<std::string, std::less<>> seen;
  std::size_t index = 0;
  for (const json::Value& list : *lists->array()) {
    const std::string at = where + ": list " + std::to_string(index++);
    const json::Object* l = list.object();
    if (l == nullptr) {
      throw DataError(at + ": must be an object");
    }
    only_members(*l, {"source", "license", "words"}, at);
    const json::Value* words = json::find(*l, "words");
    if (string_member(*l, "source", at).empty() || string_member(*l, "license", at).empty() ||
        words == nullptr || words->array() == nullptr || words->array()->empty()) {
      throw DataError(at + ": needs a source, a license and words");
    }
    for (const json::Value& w : *words->array()) {
      if (w.string() == nullptr) {
        throw DataError(at + ": every word must be a string");
      }
      if (!seen.insert(*w.string()).second) {
        throw DataError(at + ": \"" + *w.string() + "\" appears twice");
      }
      try {
        c.entries.push_back(keys(*w.string()));
      } catch (const DataError& e) {
        throw DataError(at + ": " + e.what());
      }
    }
  }
  std::sort(c.entries.begin(), c.entries.end(),
            [](const Entry& a, const Entry& b) { return a.word < b.word; });
  return c;
}

Outcome check(const Category& category, std::string_view letter, std::string_view answer) {
  if (!valid_letter(letter)) {
    throw RequestError("letter must be one Hebrew letter, not a final form");
  }
  if (utf8::rune_count(answer) > kMaxAnswerRunes) {
    return Outcome{"invalid", "too_long", "", "", ""};
  }
  std::string key = hn::normalize(answer);
  if (key.empty()) {
    return Outcome{"invalid", "empty", "", "", ""};
  }
  if (!key.starts_with(letter)) {
    return Outcome{"invalid", "wrong_letter", "", "", std::move(key)};
  }

  // The entries are sorted by word, so the first hit is the one an ORDER BY word LIMIT 1 query
  // returns (up to collation: the validator's Postgres orders by its collation, this by bytes).
  for (const Entry& e : category.entries) {
    if (e.key == key) {
      return valid(e.word, "exact", std::move(key));
    }
  }
  const std::size_t letters = utf8::rune_count(key);
  if (letters >= kMinVariantLetters) {
    const std::string spelling = hn::spelling_key(answer);
    for (const Entry& e : category.entries) {
      if (!e.spelling_key.empty() && e.spelling_key == spelling) {
        return valid(e.word, "variant", std::move(key));
      }
    }
  }
  if (letters >= kMinFuzzyLetters) {
    std::size_t candidates = 0;
    for (const Entry& e : category.entries) {
      if (e.first_letter != letter || e.letters + 1 < letters || e.letters > letters + 1) {
        continue;
      }
      if (++candidates > kFuzzyCandidates) {
        break;
      }
      if (hn::match_keys(key, e.key) == hn::MatchKind::fuzzy) {
        return valid(e.word, "fuzzy", std::move(key));
      }
    }
  }
  return Outcome{"unknown", "", "", "", std::move(key)};
}

std::string to_json(const Outcome& o) {
  std::string out = "{\"result\":" + json::quote(o.result);
  if (!o.reason.empty()) {
    out += ",\"reason\":" + json::quote(o.reason);
  }
  if (!o.match.empty()) {
    out += ",\"match\":" + json::quote(o.match);
  }
  if (!o.entry.empty()) {
    out += ",\"entry\":" + json::quote(o.entry);
  }
  out += ",\"key\":" + json::quote(o.key) + "}";
  return out;
}

}  // namespace rarebit::wordlist
