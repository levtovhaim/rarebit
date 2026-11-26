#include "utf8.hpp"

#include <cstdint>
#include <stdexcept>

namespace rarebit::utf8 {

namespace {

[[nodiscard]] unsigned byte_at(std::string_view s, std::size_t i) noexcept {
  return static_cast<unsigned char>(s[i]);
}

[[nodiscard]] bool continuation(unsigned b) noexcept { return (b & 0xC0U) == 0x80U; }

}  // namespace

std::optional<std::size_t> sequence_length(std::string_view s) noexcept {
  if (s.empty()) {
    return std::nullopt;
  }
  const unsigned b0 = byte_at(s, 0);
  if (b0 < 0x80U) {
    return 1;
  }
  // The second byte's range depends on the first (RFC 3629 §4): this rules out overlong forms,
  // surrogates (ED A0..BF) and code points past U+10FFFF (F4 90..).
  std::size_t len = 0;
  unsigned lo = 0x80U;
  unsigned hi = 0xBFU;
  if (b0 >= 0xC2U && b0 <= 0xDFU) {
    len = 2;
  } else if (b0 >= 0xE0U && b0 <= 0xEFU) {
    len = 3;
    if (b0 == 0xE0U) {
      lo = 0xA0U;
    } else if (b0 == 0xEDU) {
      hi = 0x9FU;
    }
  } else if (b0 >= 0xF0U && b0 <= 0xF4U) {
    len = 4;
    if (b0 == 0xF0U) {
      lo = 0x90U;
    } else if (b0 == 0xF4U) {
      hi = 0x8FU;
    }
  } else {
    return std::nullopt;
  }
  if (s.size() < len) {
    return std::nullopt;
  }
  const unsigned b1 = byte_at(s, 1);
  if (b1 < lo || b1 > hi) {
    return std::nullopt;
  }
  for (std::size_t i = 2; i < len; ++i) {
    if (!continuation(byte_at(s, i))) {
      return std::nullopt;
    }
  }
  return len;
}

std::size_t rune_count(std::string_view s) noexcept {
  std::size_t count = 0;
  while (!s.empty()) {
    const auto len = sequence_length(s);
    s.remove_prefix(len.value_or(1));
    ++count;
  }
  return count;
}

bool valid(std::string_view s) noexcept {
  while (!s.empty()) {
    const auto len = sequence_length(s);
    if (!len) {
      return false;
    }
    s.remove_prefix(*len);
  }
  return true;
}

void append(std::string& out, char32_t cp) {
  const auto c = static_cast<std::uint32_t>(cp);
  if (c > 0x10FFFFU || (c >= 0xD800U && c <= 0xDFFFU)) {
    throw std::invalid_argument("not a Unicode scalar value");
  }
  const auto put = [&out](std::uint32_t b) { out.push_back(static_cast<char>(b)); };
  if (c < 0x80U) {
    put(c);
  } else if (c < 0x800U) {
    put(0xC0U | (c >> 6U));
    put(0x80U | (c & 0x3FU));
  } else if (c < 0x10000U) {
    put(0xE0U | (c >> 12U));
    put(0x80U | ((c >> 6U) & 0x3FU));
    put(0x80U | (c & 0x3FU));
  } else {
    put(0xF0U | (c >> 18U));
    put(0x80U | ((c >> 12U) & 0x3FU));
    put(0x80U | ((c >> 6U) & 0x3FU));
    put(0x80U | (c & 0x3FU));
  }
}

}  // namespace rarebit::utf8
