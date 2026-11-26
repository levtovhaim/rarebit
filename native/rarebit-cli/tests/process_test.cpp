#include <gtest/gtest.h>

#include "process.hpp"

namespace p = rarebit::process;

// The C runtime's rules (CommandLineToArgvW): quote only when needed; inside quotes, double the
// backslashes that come before a quote or the closing quote.
TEST(WindowsQuote, OnlyWhenNeeded) {
  EXPECT_EQ(p::windows_quote("docker"), "docker");
  EXPECT_EQ(p::windows_quote("BOTS_URL=http://nginx:8080"), "BOTS_URL=http://nginx:8080");
  EXPECT_EQ(p::windows_quote("C:\\dir\\"), "C:\\dir\\");  // no quoting, so no doubling
  EXPECT_EQ(p::windows_quote(""), "\"\"");
  EXPECT_EQ(p::windows_quote("a b"), "\"a b\"");
  EXPECT_EQ(p::windows_quote("say \"hi\""), R"("say \"hi\"")");
  EXPECT_EQ(p::windows_quote(R"(a\"b)"), R"("a\\\"b")");
  EXPECT_EQ(p::windows_quote("dir with space\\"), R"("dir with space\\")");
  EXPECT_EQ(p::windows_quote("בת יענה"), "\"בת יענה\"");
}

#ifndef _WIN32
TEST(Run, ReturnsTheExitCode) {
  EXPECT_EQ(p::run({"sh", "-c", "exit 0"}), 0);
  EXPECT_EQ(p::run({"sh", "-c", "exit 7"}), 7);
}

TEST(Run, ArgumentsArriveUnchanged) {
  EXPECT_EQ(p::run({"sh", "-c", "[ \"$1\" = 'בת יענה \"x\"' ]", "sh", "בת יענה \"x\""}), 0);
}

TEST(Run, ASignalIs128PlusItsNumber) {
  EXPECT_EQ(p::run({"sh", "-c", "kill -KILL $$"}), 128 + 9);
}

TEST(Run, TheChildGetsDefaultSignalActions) {
  // This process ignores SIGINT while it waits; the child must not inherit that.
  EXPECT_EQ(p::run({"sh", "-c", "kill -INT $$; exit 3"}), 128 + 2);
}

TEST(Run, AMissingProgramIsAStartError) {
  EXPECT_THROW((void)p::run({"rarebit-no-such-program-x"}), p::StartError);
  EXPECT_THROW((void)p::run({}), p::StartError);
}
#endif
