#include <gtest/gtest.h>

#include "json.hpp"

namespace j = rarebit::json;

TEST(JsonParse, ObjectsArraysAndScalars) {
  const j::Value v = j::parse(R"( {"a": [1, -2.5e3, "x"], "b": {"c": true, "d": null}, "e": false} )");
  const j::Object* o = v.object();
  ASSERT_NE(o, nullptr);
  ASSERT_EQ(o->size(), 3U);
  const j::Array* a = j::find(*o, "a")->array();
  ASSERT_NE(a, nullptr);
  ASSERT_EQ(a->size(), 3U);
  EXPECT_EQ(std::get<j::Number>((*a)[1].data).text, "-2.5e3");
  EXPECT_EQ(*(*a)[2].string(), "x");
  EXPECT_EQ(j::find(*o, "missing"), nullptr);
  EXPECT_TRUE(std::get<bool>(j::find(*j::find(*o, "b")->object(), "c")->data));
}

TEST(JsonParse, StringEscapesAndUtf8) {
  EXPECT_EQ(*j::parse(R"("a\"b\\c\/d\b\f\n\r\t")").string(), "a\"b\\c/d\b\f\n\r\t");
  EXPECT_EQ(*j::parse(R"("\u05d0\u05D1")").string(), "אב");
  EXPECT_EQ(*j::parse(R"("\ud83d\ude00")").string(), "\xF0\x9F\x98\x80");
  EXPECT_EQ(*j::parse("\"חתול\"").string(), "חתול");
}

TEST(JsonParse, RejectsWhatRfc8259Rejects) {
  for (const char* bad : {
           "", "{", "[1,]", "{\"a\":1,}", "{\"a\" 1}", "01", "1.", "-", "1e", "tru", "nul",
           "\"unterminated", "\"tab\there\"", "\"\\x\"", "\"\\u12\"", "\"\\ud800\"", "\"\\udc00\"",
           "\"\\ud800\\u0041\"", "\"\xD7\"", "1 2", "{\"a\":1}x", "{\"a\":1,\"a\":2}",
       }) {
    EXPECT_THROW((void)j::parse(bad), j::ParseError) << bad;
  }
}

TEST(JsonParse, RefusesDeepNesting) {
  EXPECT_NO_THROW((void)j::parse(std::string(64, '[') + std::string(64, ']')));
  EXPECT_THROW((void)j::parse(std::string(66, '[') + std::string(66, ']')), j::ParseError);
}

TEST(JsonParse, ErrorsSayWhere) {
  try {
    (void)j::parse("[1, x]");
    FAIL() << "no error";
  } catch (const j::ParseError& e) {
    EXPECT_EQ(e.offset(), 4U);
  }
}

// The same bytes Go's encoding/json writes by default.
TEST(JsonQuote, EscapesAsGoDoes) {
  EXPECT_EQ(j::quote("חתול"), "\"חתול\"");
  EXPECT_EQ(j::quote("a\"b\\c"), R"("a\"b\\c")");
  EXPECT_EQ(j::quote("\n\r\t"), R"("\n\r\t")");
  EXPECT_EQ(j::quote(std::string("\x01\x1f", 2)), R"("\u0001\u001f")");
  EXPECT_EQ(j::quote("<a&b>"), R"("\u003ca\u0026b\u003e")");
  EXPECT_EQ(j::quote("\xE2\x80\xA8\xE2\x80\xA9"), R"("\u2028\u2029")");
  EXPECT_EQ(j::quote("a\xFF" "b"), "\"a\xEF\xBF\xBD" "b\"");
  EXPECT_EQ(j::quote("/"), "\"/\"");
}
