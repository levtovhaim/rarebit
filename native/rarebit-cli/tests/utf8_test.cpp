#include <gtest/gtest.h>

#include "utf8.hpp"

namespace u = rarebit::utf8;

TEST(Utf8, RuneCountCountsCodePoints) {
  EXPECT_EQ(u::rune_count(""), 0U);
  EXPECT_EQ(u::rune_count("abc"), 3U);
  EXPECT_EQ(u::rune_count("חתול"), 4U);
  EXPECT_EQ(u::rune_count("a\xF0\x9F\x98\x80"), 2U);  // a 4-byte emoji
}

// As Go's RuneCountInString: every byte of an invalid sequence counts as one.
TEST(Utf8, RuneCountCountsInvalidBytesOneEach) {
  EXPECT_EQ(u::rune_count("\xFF"), 1U);
  EXPECT_EQ(u::rune_count("\xC0\x80"), 2U);          // overlong NUL
  EXPECT_EQ(u::rune_count("\xED\xA0\x80"), 3U);      // a surrogate
  EXPECT_EQ(u::rune_count("\xF4\x90\x80\x80"), 4U);  // past U+10FFFF
  EXPECT_EQ(u::rune_count("\xD7"), 1U);              // a truncated Hebrew letter
  EXPECT_EQ(u::rune_count("א\x80" "ב"), 3U);
}

TEST(Utf8, Valid) {
  EXPECT_TRUE(u::valid(""));
  EXPECT_TRUE(u::valid("בת יענה"));
  EXPECT_FALSE(u::valid("\xD7"));
  EXPECT_FALSE(u::valid("\xED\xA0\x80"));
}

TEST(Utf8, Append) {
  std::string s;
  u::append(s, U'a');
  u::append(s, U'א');
  u::append(s, U'\U0001F600');
  EXPECT_EQ(s, "a\xD7\x90\xF0\x9F\x98\x80");
  EXPECT_THROW(u::append(s, static_cast<char32_t>(0xD800)), std::invalid_argument);
  EXPECT_THROW(u::append(s, static_cast<char32_t>(0x110000)), std::invalid_argument);
}
