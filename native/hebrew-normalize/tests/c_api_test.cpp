// The C API exactly as cgo sees it: snprintf-style buffers, error values, no exceptions.
#include <gtest/gtest.h>

#include <cstring>
#include <string>

#include "hebrew_normalize/hebrew_normalize.h"

TEST(CApi, ReportsTheLengthWithoutABuffer) {
  const std::string in = "שָׁלוֹם";
  EXPECT_EQ(hn_normalize(in.data(), in.size(), nullptr, 0), std::strlen("שלומ"));
}

TEST(CApi, WritesTheResultAndANul) {
  const std::string in = "שָׁלוֹם";
  char out[32];
  const size_t n = hn_normalize(in.data(), in.size(), out, sizeof out);
  EXPECT_EQ(n, std::strlen("שלומ"));
  EXPECT_STREQ(out, "שלומ");
}

TEST(CApi, TruncatesLikeSnprintf) {
  const std::string in = "abcdef";
  char out[4];
  const size_t n = hn_normalize(in.data(), in.size(), out, sizeof out);
  EXPECT_EQ(n, 6U);  // the full length: the caller retries with a bigger buffer
  EXPECT_STREQ(out, "abc");
}

TEST(CApi, NullInputIsAnErrorOnlyWithALength) {
  char out[4] = {'x', 'x', 'x', '\0'};
  EXPECT_EQ(hn_normalize(nullptr, 0, out, sizeof out), 0U);
  EXPECT_STREQ(out, "");
  EXPECT_EQ(hn_normalize(nullptr, 3, out, sizeof out), HN_ERROR);
  EXPECT_EQ(hn_match(nullptr, 1, "a", 1), HN_MATCH_ERROR);
}

TEST(CApi, InputsOverTheCapAreRejected) {
  const std::string at_cap(HN_MAX_INPUT_BYTES, 'a');
  const std::string over_cap(HN_MAX_INPUT_BYTES + 1, 'a');
  EXPECT_EQ(hn_normalize(at_cap.data(), at_cap.size(), nullptr, 0), at_cap.size());
  EXPECT_EQ(hn_normalize(over_cap.data(), over_cap.size(), nullptr, 0), HN_ERROR);
  EXPECT_EQ(hn_to_nfd(over_cap.data(), over_cap.size(), nullptr, 0), HN_ERROR);
  EXPECT_EQ(hn_match(over_cap.data(), over_cap.size(), "a", 1), HN_MATCH_ERROR);
  EXPECT_EQ(hn_match_keys("a", 1, over_cap.data(), over_cap.size()), HN_MATCH_ERROR);
}

TEST(CApi, MatchKeysAgreesWithMatchOnNormalizedKeys) {
  const char* pairs[][2] = {
      {"שלחן", "שולחן"}, {"ישראל", "יִשְׂרָאֵל"}, {"פאריז", "פריז"}, {"ים", "יום"},
      {"אמסטרדם", "רוטרדם"}, {"Café", "cafe"},   {"", "א"},         {"תל אביב", "תל-אביב"},
  };
  for (const auto& pair : pairs) {
    const std::string a = pair[0];
    const std::string e = pair[1];
    char a_key[256];
    char e_key[256];
    const size_t a_len = hn_normalize(a.data(), a.size(), a_key, sizeof a_key);
    const size_t e_len = hn_normalize(e.data(), e.size(), e_key, sizeof e_key);
    ASSERT_LT(a_len, sizeof a_key);
    ASSERT_LT(e_len, sizeof e_key);
    EXPECT_EQ(hn_match_keys(a_key, a_len, e_key, e_len), hn_match(a.data(), a.size(), e.data(), e.size()))
        << a << " / " << e;
  }
}

TEST(CApi, Match) {
  const std::string a = "שלחן";
  const std::string e = "שולחן";
  EXPECT_EQ(hn_match(a.data(), a.size(), e.data(), e.size()), HN_MATCH_VARIANT);
  EXPECT_EQ(hn_match(e.data(), e.size(), e.data(), e.size()), HN_MATCH_EXACT);
  EXPECT_EQ(hn_match("abcd", 4, "abce", 4), HN_MATCH_FUZZY);
  EXPECT_EQ(hn_match("ab", 2, "xy", 2), HN_MATCH_NONE);
}

TEST(CApi, NfdSpellingKeyAndVersions) {
  const std::string in = "שׁ";
  char out[16];
  EXPECT_EQ(hn_to_nfd(in.data(), in.size(), out, sizeof out), std::strlen("שׁ"));
  EXPECT_STREQ(out, "שׁ");
  EXPECT_EQ(hn_to_nfc(in.data(), in.size(), out, sizeof out), std::strlen("שׁ"));
  const std::string word = "שולחן";
  EXPECT_EQ(hn_spelling_key(word.data(), word.size(), out, sizeof out), std::strlen("שלחנ"));
  EXPECT_STREQ(out, "שלחנ");
  EXPECT_STRNE(hn_version(), "");
  EXPECT_STREQ(hn_unicode_version(), "16.0.0");
}
