#include "utf8.hpp"

#include <cstddef>

namespace hebrew_normalize::detail {

std::u32string decode_utf8(std::string_view in) {
  std::u32string out;
  out.reserve(in.size());
  std::size_t i = 0;
  while (i < in.size()) {
    const auto b0 = static_cast<unsigned char>(in[i]);
    if (b0 < 0x80U) {
      out.push_back(static_cast<char32_t>(b0));
      ++i;
      continue;
    }
    // Lead byte: sequence length, the payload bits, and the valid range of the second byte
    // (it rules out overlong forms, surrogates and values above U+10FFFF).
    std::size_t len = 0;
    char32_t cp = 0;
    unsigned lo = 0x80U;
    unsigned hi = 0xBFU;
    if (b0 >= 0xC2U && b0 <= 0xDFU) {
      len = 2;
      cp = static_cast<char32_t>(b0 & 0x1FU);
    } else if (b0 >= 0xE0U && b0 <= 0xEFU) {
      len = 3;
      cp = static_cast<char32_t>(b0 & 0x0FU);
      if (b0 == 0xE0U) {
        lo = 0xA0U;
      } else if (b0 == 0xEDU) {
        hi = 0x9FU;
      }
    } else if (b0 >= 0xF0U && b0 <= 0xF4U) {
      len = 4;
      cp = static_cast<char32_t>(b0 & 0x07U);
      if (b0 == 0xF0U) {
        lo = 0x90U;
      } else if (b0 == 0xF4U) {
        hi = 0x8FU;
      }
    } else {
      out.push_back(kReplacement);
      ++i;
      continue;
    }

    bool valid = i + len <= in.size();
    for (std::size_t k = 1; valid && k < len; ++k) {
      const auto b = static_cast<unsigned>(static_cast<unsigned char>(in[i + k]));
      const unsigned k_lo = (k == 1) ? lo : 0x80U;
      const unsigned k_hi = (k == 1) ? hi : 0xBFU;
      if (b < k_lo || b > k_hi) {
        valid = false;
      } else {
        cp = static_cast<char32_t>((static_cast<unsigned>(cp) << 6U) | (b & 0x3FU));
      }
    }
    if (!valid) {
      out.push_back(kReplacement);
      ++i;
      continue;
    }
    out.push_back(cp);
    i += len;
  }
  return out;
}

void append_utf8(std::string& out, char32_t cp) {
  auto v = static_cast<unsigned>(cp);
  if (v > 0x10FFFFU || (v >= 0xD800U && v <= 0xDFFFU)) {
    v = static_cast<unsigned>(kReplacement);
  }
  if (v < 0x80U) {
    out.push_back(static_cast<char>(v));
  } else if (v < 0x800U) {
    out.push_back(static_cast<char>(0xC0U | (v >> 6U)));
    out.push_back(static_cast<char>(0x80U | (v & 0x3FU)));
  } else if (v < 0x10000U) {
    out.push_back(static_cast<char>(0xE0U | (v >> 12U)));
    out.push_back(static_cast<char>(0x80U | ((v >> 6U) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | (v & 0x3FU)));
  } else {
    out.push_back(static_cast<char>(0xF0U | (v >> 18U)));
    out.push_back(static_cast<char>(0x80U | ((v >> 12U) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | ((v >> 6U) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | (v & 0x3FU)));
  }
}

std::string encode_utf8(std::u32string_view in) {
  std::string out;
  out.reserve(in.size() * 2);
  for (const char32_t cp : in) {
    append_utf8(out, cp);
  }
  return out;
}

}  // namespace hebrew_normalize::detail
