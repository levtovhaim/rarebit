#include "json.hpp"

#include <array>
#include <cstdint>

#include "utf8.hpp"

namespace rarebit::json {

namespace {

constexpr int kMaxDepth = 64;

class Parser {
 public:
  explicit Parser(std::string_view text) : text_(text) {}

  Value parse_document() {
    skip_whitespace();
    Value v = parse_value(0);
    skip_whitespace();
    if (pos_ != text_.size()) {
      fail("unexpected text after the value");
    }
    return v;
  }

 private:
  [[noreturn]] void fail(const std::string& what) const { throw ParseError(what, pos_); }

  [[nodiscard]] bool at_end() const noexcept { return pos_ >= text_.size(); }
  [[nodiscard]] char peek() const noexcept { return text_[pos_]; }

  void skip_whitespace() noexcept {
    while (!at_end() && (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r')) {
      ++pos_;
    }
  }

  void expect(char c) {
    if (at_end() || peek() != c) {
      fail(std::string("expected '") + c + "'");
    }
    ++pos_;
  }

  void expect_word(std::string_view word) {
    if (text_.substr(pos_, word.size()) != word) {
      fail("expected " + std::string(word));
    }
    pos_ += word.size();
  }

  Value parse_value(int depth) {
    if (depth > kMaxDepth) {
      fail("nested too deeply");
    }
    if (at_end()) {
      fail("expected a value");
    }
    switch (peek()) {
      case '{':
        return Value{parse_object(depth)};
      case '[':
        return Value{parse_array(depth)};
      case '"':
        return Value{parse_string()};
      case 't':
        expect_word("true");
        return Value{true};
      case 'f':
        expect_word("false");
        return Value{false};
      case 'n':
        expect_word("null");
        return Value{nullptr};
      default:
        return Value{parse_number()};
    }
  }

  Object parse_object(int depth) {
    expect('{');
    Object members;
    skip_whitespace();
    if (!at_end() && peek() == '}') {
      ++pos_;
      return members;
    }
    for (;;) {
      skip_whitespace();
      if (at_end() || peek() != '"') {
        fail("expected a member name");
      }
      std::string name = parse_string();
      if (find(members, name) != nullptr) {
        fail("duplicate member \"" + name + "\"");
      }
      skip_whitespace();
      expect(':');
      skip_whitespace();
      Value value = parse_value(depth + 1);
      members.emplace_back(std::move(name), std::move(value));
      skip_whitespace();
      if (!at_end() && peek() == ',') {
        ++pos_;
        continue;
      }
      expect('}');
      return members;
    }
  }

  Array parse_array(int depth) {
    expect('[');
    Array items;
    skip_whitespace();
    if (!at_end() && peek() == ']') {
      ++pos_;
      return items;
    }
    for (;;) {
      skip_whitespace();
      items.push_back(parse_value(depth + 1));
      skip_whitespace();
      if (!at_end() && peek() == ',') {
        ++pos_;
        continue;
      }
      expect(']');
      return items;
    }
  }

  unsigned parse_hex4() {
    if (text_.size() - pos_ < 4) {
      fail("expected four hex digits");
    }
    unsigned v = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[pos_++];
      v <<= 4U;
      if (c >= '0' && c <= '9') {
        v |= static_cast<unsigned>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        v |= static_cast<unsigned>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        v |= static_cast<unsigned>(c - 'A' + 10);
      } else {
        --pos_;
        fail("expected a hex digit");
      }
    }
    return v;
  }

  std::string parse_string() {
    expect('"');
    std::string out;
    for (;;) {
      if (at_end()) {
        fail("unterminated string");
      }
      const auto b = static_cast<unsigned char>(peek());
      if (b == '"') {
        ++pos_;
        return out;
      }
      if (b < 0x20U) {
        fail("control character in a string");
      }
      if (b == '\\') {
        ++pos_;
        if (at_end()) {
          fail("unterminated escape");
        }
        const char e = text_[pos_++];
        switch (e) {
          case '"':
          case '\\':
          case '/':
            out.push_back(e);
            break;
          case 'b':
            out.push_back('\b');
            break;
          case 'f':
            out.push_back('\f');
            break;
          case 'n':
            out.push_back('\n');
            break;
          case 'r':
            out.push_back('\r');
            break;
          case 't':
            out.push_back('\t');
            break;
          case 'u': {
            unsigned cp = parse_hex4();
            if (cp >= 0xDC00U && cp <= 0xDFFFU) {
              fail("unpaired low surrogate");
            }
            if (cp >= 0xD800U && cp <= 0xDBFFU) {
              if (text_.substr(pos_, 2) != "\\u") {
                fail("unpaired high surrogate");
              }
              pos_ += 2;
              const unsigned low = parse_hex4();
              if (low < 0xDC00U || low > 0xDFFFU) {
                fail("unpaired high surrogate");
              }
              cp = 0x10000U + ((cp - 0xD800U) << 10U) + (low - 0xDC00U);
            }
            utf8::append(out, static_cast<char32_t>(cp));
            break;
          }
          default:
            --pos_;
            fail("invalid escape");
        }
        continue;
      }
      const auto len = utf8::sequence_length(text_.substr(pos_));
      if (!len) {
        fail("invalid UTF-8 in a string");
      }
      out.append(text_.substr(pos_, *len));
      pos_ += *len;
    }
  }

  Number parse_number() {
    const std::size_t start = pos_;
    const auto digits = [this] {
      const std::size_t from = pos_;
      while (!at_end() && peek() >= '0' && peek() <= '9') {
        ++pos_;
      }
      return pos_ - from;
    };
    if (!at_end() && peek() == '-') {
      ++pos_;
    }
    if (!at_end() && peek() == '0') {
      ++pos_;
    } else if (digits() == 0) {
      pos_ = start;
      fail("expected a value");
    }
    if (!at_end() && peek() == '.') {
      ++pos_;
      if (digits() == 0) {
        fail("expected a digit after the decimal point");
      }
    }
    if (!at_end() && (peek() == 'e' || peek() == 'E')) {
      ++pos_;
      if (!at_end() && (peek() == '+' || peek() == '-')) {
        ++pos_;
      }
      if (digits() == 0) {
        fail("expected a digit in the exponent");
      }
    }
    return Number{std::string(text_.substr(start, pos_ - start))};
  }

  std::string_view text_;
  std::size_t pos_ = 0;
};

}  // namespace

Value parse(std::string_view text) { return Parser(text).parse_document(); }

const Value* find(const Object& object, std::string_view name) noexcept {
  for (const auto& [key, value] : object) {
    if (key == name) {
      return &value;
    }
  }
  return nullptr;
}

std::string quote(std::string_view s) {
  static constexpr std::array<char, 16> kHex = {'0', '1', '2', '3', '4', '5', '6', '7',
                                                '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
  std::string out = "\"";
  const auto u00 = [&out](unsigned b) {
    out += "\\u00";
    out.push_back(kHex[(b >> 4U) & 0xFU]);
    out.push_back(kHex[b & 0xFU]);
  };
  while (!s.empty()) {
    const auto b = static_cast<unsigned char>(s.front());
    if (b < 0x80U) {
      switch (b) {
        case '"':
          out += "\\\"";
          break;
        case '\\':
          out += "\\\\";
          break;
        case '\n':
          out += "\\n";
          break;
        case '\r':
          out += "\\r";
          break;
        case '\t':
          out += "\\t";
          break;
        case '<':
        case '>':
        case '&':
          u00(b);
          break;
        default:
          if (b < 0x20U) {
            u00(b);
          } else {
            out.push_back(static_cast<char>(b));
          }
      }
      s.remove_prefix(1);
      continue;
    }
    const auto len = utf8::sequence_length(s);
    if (!len) {
      out += "\xEF\xBF\xBD";  // U+FFFD
      s.remove_prefix(1);
      continue;
    }
    const std::string_view seq = s.substr(0, *len);
    if (seq == "\xE2\x80\xA8") {
      out += "\\u2028";
    } else if (seq == "\xE2\x80\xA9") {
      out += "\\u2029";
    } else {
      out.append(seq);
    }
    s.remove_prefix(*len);
  }
  out.push_back('"');
  return out;
}

}  // namespace rarebit::json
