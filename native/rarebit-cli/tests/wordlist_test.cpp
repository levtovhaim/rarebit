#include <gtest/gtest.h>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>

#include "wordlist.hpp"

namespace w = rarebit::wordlist;
namespace fs = std::filesystem;

namespace {

const fs::path kFixture = RAREBIT_CLI_TEST_DATA;

w::Outcome check(std::string_view letter, std::string_view answer) {
  static const w::Category animal = w::load(kFixture, "animal");
  return w::check(animal, letter, answer);
}

// A temporary category directory with one file, removed afterwards.
class TempCategory {
 public:
  explicit TempCategory(const std::string& json)
      : dir_(fs::temp_directory_path() /
             ("rarebit-cli-test-" + std::to_string(reinterpret_cast<std::uintptr_t>(this)))) {
    fs::create_directories(dir_);
    std::ofstream(dir_ / "animal.json", std::ios::binary) << json;
  }
  ~TempCategory() {
    std::error_code ec;
    fs::remove_all(dir_, ec);
  }
  TempCategory(const TempCategory&) = delete;
  TempCategory& operator=(const TempCategory&) = delete;
  [[nodiscard]] const fs::path& dir() const { return dir_; }

 private:
  fs::path dir_;
};

std::string category_json(const std::string& lists) {
  return R"({"id":"animal","name":"חי","kind":"regular","lists":)" + lists + "}";
}

}  // namespace

TEST(WordlistLoad, ReadsEveryListSortedByWord) {
  const w::Category c = w::load(kFixture, "animal");
  EXPECT_EQ(c.id, "animal");
  EXPECT_EQ(c.name, "חי");
  ASSERT_EQ(c.entries.size(), 7U);
  for (std::size_t i = 1; i < c.entries.size(); ++i) {
    EXPECT_LT(c.entries[i - 1].word, c.entries[i].word);
  }
}

TEST(WordlistLoad, KeysAsTheContentLoadComputesThem) {
  const w::Entry giraffe = w::keys("ג'ירפה");
  EXPECT_EQ(giraffe.key, "גירפה");
  EXPECT_EQ(giraffe.first_letter, "ג");
  EXPECT_EQ(giraffe.letters, 5U);
  EXPECT_FALSE(giraffe.spelling_key.empty());
  const w::Entry fish = w::keys("דג");  // under 3 letters: no spelling key
  EXPECT_EQ(fish.letters, 2U);
  EXPECT_TRUE(fish.spelling_key.empty());
  EXPECT_THROW((void)w::keys("abc"), w::DataError);
  EXPECT_THROW((void)w::keys("!!"), w::DataError);
}

TEST(WordlistLoad, EveryRealCategoryLoads) {
  std::size_t files = 0;
  for (const auto& f : fs::directory_iterator(RAREBIT_REPO_DATA)) {
    if (f.path().extension() == ".json") {
      const w::Category c = w::load(RAREBIT_REPO_DATA, f.path().stem().string());
      EXPECT_FALSE(c.entries.empty()) << f.path();
      ++files;
    }
  }
  EXPECT_GE(files, 6U);
}

TEST(WordlistLoad, UnknownCategoriesAreRequestErrors) {
  EXPECT_THROW((void)w::load(kFixture, "plant"), w::RequestError);
  EXPECT_THROW((void)w::load(kFixture, "../categories/animal"), w::RequestError);
  EXPECT_THROW((void)w::load(kFixture, "Animal"), w::RequestError);
  EXPECT_THROW((void)w::load(kFixture, ""), w::RequestError);
}

TEST(WordlistLoad, RejectsWhatTheContentLoadRejects) {
  const std::string ok_list = R"([{"source":"s","license":"MIT","words":["כלב"]}])";
  EXPECT_NO_THROW((void)w::load(TempCategory(category_json(ok_list)).dir(), "animal"));
  for (const std::string& bad : {
           std::string("not json"),
           std::string("[]"),
           category_json(R"([{"source":"s","license":"MIT","words":["כלב"],"extra":1}])"),
           category_json(R"([{"source":"","license":"MIT","words":["כלב"]}])"),
           category_json(R"([{"source":"s","license":"MIT","words":[]}])"),
           category_json(R"([{"source":"s","license":"MIT","words":["כלב","כלב"]}])"),
           category_json(R"([{"source":"s","license":"MIT","words":["כלב"]},{"source":"t","license":"MIT","words":["כלב"]}])"),
           category_json(R"([{"source":"s","license":"MIT","words":["dog"]}])"),
           category_json(R"([{"source":"s","license":"MIT","words":[1]}])"),
           category_json("[]"),
           R"({"id":"plant","name":"צומח","kind":"regular","lists":)" + ok_list + "}",
           R"({"id":"animal","name":"","kind":"regular","lists":)" + ok_list + "}",
           R"({"id":"animal","name":"חי","kind":"other","lists":)" + ok_list + "}",
           R"({"id":"animal","name":"חי","kind":"regular","lists":)" + ok_list + R"(,"more":true})",
       }) {
    EXPECT_THROW((void)w::load(TempCategory(bad).dir(), "animal"), w::DataError) << bad;
  }
}

TEST(WordlistCheck, ExactKeyMatch) {
  const w::Outcome o = check("ח", "חתול");
  EXPECT_EQ(o.result, "valid");
  EXPECT_EQ(o.match, "exact");
  EXPECT_EQ(o.entry, "חתול");
  EXPECT_EQ(o.key, "חתול");
  EXPECT_EQ(check("ח", "חָתוּל").match, "exact");   // niqqud
  EXPECT_EQ(check("ג", "גירפה").entry, "ג'ירפה");   // punctuation
  EXPECT_EQ(check("ב", "בת-יענה").entry, "בת יענה");
}

TEST(WordlistCheck, SpellingVariant) {
  const w::Outcome o = check("ת", "תרנגל");  // without the vav of full spelling
  EXPECT_EQ(o.result, "valid");
  EXPECT_EQ(o.match, "variant");
  EXPECT_EQ(o.entry, "תרנגול");
}

TEST(WordlistCheck, OneEditTypo) {
  const w::Outcome o = check("ג", "גירפא");
  EXPECT_EQ(o.result, "valid");
  EXPECT_EQ(o.match, "fuzzy");
  EXPECT_EQ(o.entry, "ג'ירפה");
  // Under 4 letters there's no typo match: one edit is too much of a short word.
  EXPECT_EQ(check("כ", "כלא").result, "unknown");
}

TEST(WordlistCheck, Unknown) {
  const w::Outcome o = check("ח", "חמור");
  EXPECT_EQ(o.result, "unknown");
  EXPECT_EQ(o.key, "חמור");
  EXPECT_TRUE(o.entry.empty());
}

TEST(WordlistCheck, Invalid) {
  EXPECT_EQ(check("ח", "כלב").reason, "wrong_letter");
  EXPECT_EQ(check("ח", "כלב").key, "כלב");
  EXPECT_EQ(check("ח", "!?").reason, "empty");
  EXPECT_EQ(check("ח", std::string(65, 'a')).reason, "too_long");
  std::string long_hebrew;
  for (int i = 0; i < 64; ++i) {
    long_hebrew += "ח";
  }
  EXPECT_NE(check("ח", long_hebrew).reason, "too_long");  // 64 is the limit, not over it
  EXPECT_EQ(check("ח", long_hebrew + "ח").reason, "too_long");
}

TEST(WordlistCheck, RejectsLettersARoundCantUse) {
  for (const char* letter : {"ך", "ם", "a", "חת", "", "\xD7"}) {
    EXPECT_THROW((void)check(letter, "חתול"), w::RequestError) << letter;
  }
}

TEST(WordlistJson, TheValidatorsShape) {
  EXPECT_EQ(w::to_json({"valid", "", "exact", "חתול", "חתול"}),
            R"({"result":"valid","match":"exact","entry":"חתול","key":"חתול"})");
  EXPECT_EQ(w::to_json({"invalid", "too_long", "", "", ""}), R"({"result":"invalid","reason":"too_long","key":""})");
  EXPECT_EQ(w::to_json({"unknown", "", "", "", "חמור"}), R"({"result":"unknown","key":"חמור"})");
}
