#include <gtest/gtest.h>

#include <string>

#include "hebrew_normalize/hebrew_normalize.hpp"

using hebrew_normalize::normalize;
using hebrew_normalize::spelling_key;

TEST(Normalize, StripsNiqqudAndCantillation) {
  EXPECT_EQ(normalize("שָׁלוֹם"), "שלומ");
  EXPECT_EQ(normalize("בְּרֵאשִׁ֖ית"), "בראשית");
}

TEST(Normalize, MapsFinalLettersToRegularForms) { EXPECT_EQ(normalize("ךםןףץ"), "כמנפצ"); }

TEST(Normalize, DropsSpacesAndPunctuation) {
  EXPECT_EQ(normalize(" תל־אביב, יפו! "), "תלאביביפו");
  EXPECT_EQ(normalize("תל-אביב"), "תלאביב");
  EXPECT_EQ(normalize("צה\"ל"), "צהל");
  EXPECT_EQ(normalize("צה״ל"), "צהל");
  EXPECT_EQ(normalize("ג׳ירפה"), "גירפה");
  EXPECT_EQ(normalize("ג'ירפה"), "גירפה");
}

TEST(Normalize, PresentationFormsBecomePlainLetters) {
  EXPECT_EQ(normalize("שׁלום"), normalize("שלום"));  // shin with shin dot
  EXPECT_EQ(normalize("ﭏ"), "אל");                                 // alef-lamed ligature
  EXPECT_EQ(normalize("ﬡ"), "א");                                  // wide alef
}

TEST(Normalize, YiddishLigaturesAreSpelledOut) {
  EXPECT_EQ(normalize("װ"), "וו");
  EXPECT_EQ(normalize("ױ"), "וי");
  EXPECT_EQ(normalize("ײ"), "יי");
  EXPECT_EQ(normalize("ײַ"), "יי");  // U+05F2 with patah, as one presentation form
}

TEST(Normalize, NfcAndNfdInputGiveTheSameKey) {
  const std::string composed = "שָּׁ";                 // shin with dagesh and shin dot, qamats
  const std::string decomposed = "שָּׁ";   // the same, decomposed
  const std::string reordered = "שָּׁ";    // marks in another order
  EXPECT_EQ(normalize(composed), "ש");
  EXPECT_EQ(normalize(decomposed), "ש");
  EXPECT_EQ(normalize(reordered), "ש");
  EXPECT_EQ(normalize("Café"), normalize("Café"));  // Latin, as macOS writes NFD
}

TEST(Normalize, FoldsLatinToLowercaseAscii) {
  EXPECT_EQ(normalize("Café"), "cafe");
  EXPECT_EQ(normalize("iPhone 15"), "iphone15");
  EXPECT_EQ(normalize("Škoda"), "skoda");
}

TEST(Normalize, DropsOtherScriptsAndSymbols) {
  EXPECT_EQ(normalize("Москва"), "");
  EXPECT_EQ(normalize("😀 תפוז"), "תפוז");
}

TEST(Normalize, DropsInvalidUtf8) {
  EXPECT_EQ(normalize(std::string("א\xFF" "ב")), "אב");
  EXPECT_EQ(normalize(std::string("\xC0\xAF")), "");      // overlong "/"
  EXPECT_EQ(normalize(std::string("\xED\xA0\x80")), "");  // UTF-16 surrogate
  EXPECT_EQ(normalize(std::string("\xF4\x90\x80\x80")), "");  // above U+10FFFF
  EXPECT_EQ(normalize(std::string("\xD7")), "");          // truncated
}

TEST(Normalize, EmptyAndWhitespaceOnly) {
  EXPECT_EQ(normalize(""), "");
  EXPECT_EQ(normalize("  \t\n"), "");
}

TEST(SpellingKey, FullAndDefectiveSpellingAgree) {
  EXPECT_EQ(spelling_key("שולחן"), spelling_key("שלחן"));
  EXPECT_EQ(spelling_key("תוכנית"), spelling_key("תכנית"));
  EXPECT_EQ(spelling_key("ירושלים"), spelling_key("ירושלם"));
  EXPECT_EQ(spelling_key("וושינגטון"), spelling_key("ושינגטון"));
  EXPECT_EQ(spelling_key("ירושליים"), spelling_key("ירושלים"));
}

TEST(SpellingKey, KeepsTheFirstAndLastLetter) {
  EXPECT_EQ(spelling_key("יום"), "ימ");
  EXPECT_EQ(spelling_key("ויו"), "וו");
  EXPECT_EQ(spelling_key("ים"), "ימ");  // two letters: unchanged
}
