#include <gtest/gtest.h>

#include <cstddef>
#include <random>
#include <string>

#include "hebrew_normalize/hebrew_normalize.hpp"
#include "internal.hpp"

using hebrew_normalize::edit_distance;
using hebrew_normalize::match;
using hebrew_normalize::MatchKind;

TEST(Match, ExactAfterNormalization) {
  EXPECT_EQ(match("ישראל", "יִשְׂרָאֵל"), MatchKind::exact);
  EXPECT_EQ(match("תל אביב", "תל-אביב"), MatchKind::exact);
  EXPECT_EQ(match("ניו יורק", "ניו-יורק"), MatchKind::exact);
}

TEST(Match, VariantSpelling) {
  EXPECT_EQ(match("שלחן", "שולחן"), MatchKind::variant);
  EXPECT_EQ(match("תכנית", "תוכנית"), MatchKind::variant);
  EXPECT_EQ(match("חתל", "חתול"), MatchKind::variant);
}

TEST(Match, FuzzyIsOneEditOnFourOrMoreLetters) {
  EXPECT_EQ(match("אמסתרדם", "אמסטרדם"), MatchKind::fuzzy);  // substitution
  EXPECT_EQ(match("פאריז", "פריז"), MatchKind::fuzzy);       // insertion
  EXPECT_EQ(match("פריז", "פאריז"), MatchKind::fuzzy);       // deletion
}

TEST(Match, ShortWordsNeedAnExactMatch) {
  EXPECT_EQ(match("ים", "יום"), MatchKind::none);  // sea vs day
  EXPECT_EQ(match("גן", "גז"), MatchKind::none);
  EXPECT_EQ(match("דג", "דג"), MatchKind::exact);
}

TEST(Match, TwoEditsIsNoMatch) {
  EXPECT_EQ(match("אמסטרדם", "רוטרדם"), MatchKind::none);
  EXPECT_EQ(match("תפוח", "תפוזים"), MatchKind::none);
}

TEST(Match, EmptyIsNeverAMatch) {
  EXPECT_EQ(match("", "ירושלים"), MatchKind::none);
  EXPECT_EQ(match("!!!", "!!!"), MatchKind::none);
  EXPECT_EQ(match("", ""), MatchKind::none);
}

TEST(EditDistance, Basics) {
  EXPECT_EQ(edit_distance("", ""), 0U);
  EXPECT_EQ(edit_distance("אבג", "אבג"), 0U);
  EXPECT_EQ(edit_distance("אבג", "אבד"), 1U);
  EXPECT_EQ(edit_distance("אבג", "אג"), 1U);
  EXPECT_EQ(edit_distance("", "אבג"), 3U);
  EXPECT_EQ(edit_distance("kitten", "sitting"), 3U);
}

// within_one_edit is the linear-time check match() uses; it must agree with the full distance.
TEST(EditDistance, WithinOneAgreesWithTheFullDistance) {
  std::mt19937 rng(20261124);
  std::uniform_int_distribution<int> length(0, 6);
  std::uniform_int_distribution<int> letter(0, 3);  // a small alphabet makes near-misses common
  auto random_word = [&] {
    std::u32string word;
    const int n = length(rng);
    for (int i = 0; i < n; ++i) {
      word.push_back(static_cast<char32_t>(0x05D0 + letter(rng)));
    }
    return word;
  };
  for (int i = 0; i < 20000; ++i) {
    const std::u32string a = random_word();
    const std::u32string b = random_word();
    ASSERT_EQ(hebrew_normalize::detail::within_one_edit(a, b), hebrew_normalize::detail::edit_distance_cp(a, b) <= 1)
        << "iteration " << i;
  }
}
