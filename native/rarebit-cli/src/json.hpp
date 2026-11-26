// A small, strict JSON reader for the word-list files (RFC 8259), and the string escaping the
// validator's JSON output uses. No dependency: the files are ours, with a fixed shape
// (data/README.md), and checked by data/tools/check_data.py.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

namespace rarebit::json {

struct Value;
using Array = std::vector<Value>;
// Members in file order. Duplicate names are an error when parsing.
using Object = std::vector<std::pair<std::string, Value>>;
// Numbers keep their text: the word lists have none, and nothing here does arithmetic.
struct Number {
  std::string text;
};

struct Value {
  std::variant<std::nullptr_t, bool, Number, std::string, Array, Object> data;

  [[nodiscard]] const std::string* string() const noexcept { return std::get_if<std::string>(&data); }
  [[nodiscard]] const Array* array() const noexcept { return std::get_if<Array>(&data); }
  [[nodiscard]] const Object* object() const noexcept { return std::get_if<Object>(&data); }
};

class ParseError : public std::runtime_error {
 public:
  ParseError(const std::string& what, std::size_t offset)
      : std::runtime_error(what + " at byte " + std::to_string(offset)), offset_(offset) {}
  [[nodiscard]] std::size_t offset() const noexcept { return offset_; }

 private:
  std::size_t offset_;
};

// Parses one JSON text: whitespace around one value, nothing else. Strings must be valid UTF-8;
// \u escapes, surrogate pairs included, are decoded. Nesting deeper than 64 is refused.
[[nodiscard]] Value parse(std::string_view text);

// The member called name, or nullptr.
[[nodiscard]] const Value* find(const Object& object, std::string_view name) noexcept;

// s as a JSON string literal, quotes included, escaped as Go's encoding/json does by default:
// \" \\ \n \r \t, other control characters and < > & as \u00XX, U+2028 and U+2029 as   and
//  , invalid UTF-8 replaced by U+FFFD. Other characters stay as they are.
[[nodiscard]] std::string quote(std::string_view s);

}  // namespace rarebit::json
