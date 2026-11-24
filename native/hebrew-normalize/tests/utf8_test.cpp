#include <gtest/gtest.h>

#include <string>

#include "utf8.hpp"

using hebrew_normalize::detail::decode_utf8;
using hebrew_normalize::detail::encode_utf8;
using hebrew_normalize::detail::kReplacement;

TEST(Utf8, RoundTripsEveryScalarValueInTheHebrewScopeAndBeyond) {
  for (char32_t cp : {U'A', U'é', U'א', U'ת', U'שׁ', U'�', U'\U0001F600'}) {
    const std::u32string one(1, cp);
    EXPECT_EQ(decode_utf8(encode_utf8(one)), one) << static_cast<unsigned>(cp);
  }
  for (char32_t cp = 0x0590; cp <= 0x05FF; ++cp) {
    const std::u32string one(1, cp);
    ASSERT_EQ(decode_utf8(encode_utf8(one)), one);
  }
}

TEST(Utf8, EachInvalidByteBecomesOneReplacement) {
  EXPECT_EQ(decode_utf8(std::string("\xFF")), std::u32string(1, kReplacement));
  EXPECT_EQ(decode_utf8(std::string("\x80")), std::u32string(1, kReplacement));          // lone continuation
  EXPECT_EQ(decode_utf8(std::string("\xC0\xAF")), std::u32string(2, kReplacement));      // overlong
  EXPECT_EQ(decode_utf8(std::string("\xE0\x80\xAF")), std::u32string(3, kReplacement));  // overlong
  EXPECT_EQ(decode_utf8(std::string("\xED\xA0\x80")), std::u32string(3, kReplacement));  // surrogate
  EXPECT_EQ(decode_utf8(std::string("\xF4\x90\x80\x80")), std::u32string(4, kReplacement));  // > U+10FFFF
  EXPECT_EQ(decode_utf8(std::string("\xD7")), std::u32string(1, kReplacement));          // truncated
}

TEST(Utf8, EncodeReplacesSurrogatesAndOutOfRange) {
  EXPECT_EQ(encode_utf8(std::u32string(1, static_cast<char32_t>(0xD800))), "�");
  EXPECT_EQ(encode_utf8(std::u32string(1, static_cast<char32_t>(0x110000))), "�");
}
