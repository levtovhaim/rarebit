#include <gtest/gtest.h>

#include <sstream>
#include <string>
#include <vector>

#include "cli.hpp"
#include "process.hpp"

namespace c = rarebit::cli;

namespace {

struct Result {
  int code;
  std::string out;
  std::string err;
  std::vector<std::string> ran;  // what the runner was asked to start
};

Result run(const std::vector<std::string>& args, int runner_code = 0, bool docker_missing = false) {
  Result r{};
  std::ostringstream out;
  std::ostringstream err;
  const c::Runner runner = [&r, runner_code, docker_missing](const std::vector<std::string>& cmd) {
    r.ran = cmd;
    if (docker_missing) {
      throw rarebit::process::StartError("can't start docker: No such file or directory");
    }
    return runner_code;
  };
  r.code = c::run(args, out, err, runner);
  r.out = out.str();
  r.err = err.str();
  return r;
}

const std::string kData = RAREBIT_CLI_TEST_DATA;

}  // namespace

TEST(CliCheck, ValidExitsZeroWithTheValidatorsJson) {
  const Result r = run({"check", "--data", kData, "--json", "animal", "ח", "חתול"});
  EXPECT_EQ(r.code, c::kOk);
  EXPECT_EQ(r.out, "{\"result\":\"valid\",\"match\":\"exact\",\"entry\":\"חתול\",\"key\":\"חתול\"}\n");
  EXPECT_EQ(r.err, "");
}

TEST(CliCheck, NotValidExitsOne) {
  EXPECT_EQ(run({"check", "--data=" + kData, "animal", "ח", "חמור"}).code, c::kNotValid);
  EXPECT_EQ(run({"check", "--data=" + kData, "animal", "ח", "כלב"}).code, c::kNotValid);
}

TEST(CliCheck, TextOutput) {
  const Result r = run({"check", "--data", kData, "animal", "ת", "תרנגל"});
  EXPECT_EQ(r.out, "valid: spelling variant of \"תרנגול\"\nkey: תרנגל\n");
  EXPECT_EQ(run({"check", "--data", kData, "animal", "ח", "חמור"}).out,
            "unknown: not in the word lists; in a game, the room votes on it\nkey: חמור\n");
  EXPECT_EQ(run({"check", "--data", kData, "animal", "ח", "כלב"}).out, "invalid: doesn't start with ח\nkey: כלב\n");
}

TEST(CliCheck, AnAnswerThatLooksLikeAnOption) {
  EXPECT_EQ(run({"check", "--data", kData, "animal", "ח", "--", "--x"}).out, "invalid: doesn't start with ח\nkey: x\n");
  EXPECT_EQ(run({"check", "--data", kData, "animal", "ח", "--", "--"}).out, "invalid: no letters\n");
}

TEST(CliCheck, UsageErrorsExitTwo) {
  EXPECT_EQ(run({"check"}).code, c::kUsage);
  EXPECT_EQ(run({"check", "animal", "ח"}).code, c::kUsage);
  EXPECT_EQ(run({"check", "--data"}).code, c::kUsage);
  EXPECT_EQ(run({"check", "--bogus", "animal", "ח", "x"}).code, c::kUsage);
  const Result unknown = run({"check", "--data", kData, "plant", "צ", "צבר"});
  EXPECT_EQ(unknown.code, c::kUsage);
  EXPECT_NE(unknown.err.find("unknown category \"plant\""), std::string::npos) << unknown.err;
  const Result letter = run({"check", "--data", kData, "animal", "ך", "x"});
  EXPECT_EQ(letter.code, c::kUsage);
  EXPECT_NE(letter.err.find("not a final form"), std::string::npos) << letter.err;
}

TEST(CliNormalize, Keys) {
  EXPECT_EQ(run({"normalize", "תַּרְנְגוֹל"}).out, "key: תרנגול\nspelling key: תרנגל\nletters: 6\n");
  EXPECT_EQ(run({"normalize", "--json", "דג"}).out, "{\"key\":\"דג\",\"spelling_key\":\"דג\",\"letters\":2}\n");
  EXPECT_EQ(run({"normalize"}).code, c::kUsage);
}

TEST(CliBots, RunsTheImageOnTheLocalStack) {
  const Result r = run({"bots", "synthetic", "--timeout", "300"}, 0);
  EXPECT_EQ(r.code, 0);
  const std::vector<std::string> want = {
      "docker", "run", "--rm", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
      "--network", "rarebit_default", "-e", "BOTS_URL=http://nginx:8080", "-e", "BOTS_ORIGIN=http://localhost:8080",
      "rarebit-bots:dev", "synthetic", "--timeout", "300"};
  EXPECT_EQ(r.ran, want);
}

TEST(CliBots, OptionsBeforeTheModeAreOurs) {
  const Result r = run({"bots", "--image", "bots:x", "--network=bridge", "--url", "https://game.example",
                        "--origin=", "observe", "--url", "https://other.example"});
  const std::vector<std::string> want = {
      "docker", "run", "--rm", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
      "--network", "bridge", "-e", "BOTS_URL=https://game.example", "bots:x", "observe", "--url",
      "https://other.example"};
  EXPECT_EQ(r.ran, want);
}

TEST(CliBots, PassesTheBotsExitCodeOn) {
  EXPECT_EQ(run({"bots", "synthetic"}, 1).code, 1);
  EXPECT_EQ(run({"bots", "synthetic"}, 2).code, 2);
}

TEST(CliBots, DryRunPrintsAndStartsNothing) {
  const Result r = run({"bots", "--dry-run", "load", "--rooms", "5"});
  EXPECT_TRUE(r.ran.empty());
  EXPECT_EQ(r.out,
            "docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges --network rarebit_default "
            "-e BOTS_URL=http://nginx:8080 -e BOTS_ORIGIN=http://localhost:8080 rarebit-bots:dev load --rooms 5\n");
}

TEST(CliBots, NoDocker) {
  const Result r = run({"bots", "synthetic"}, 0, true);
  EXPECT_EQ(r.code, c::kNoDocker);
  EXPECT_NE(r.err.find("Docker installed"), std::string::npos) << r.err;
}

TEST(CliBots, NeedsAMode) {
  EXPECT_EQ(run({"bots"}).code, c::kUsage);
  EXPECT_EQ(run({"bots", "--image", "x"}).code, c::kUsage);
}

TEST(Cli, HelpVersionAndUnknownCommands) {
  EXPECT_EQ(run({}).code, c::kUsage);
  EXPECT_EQ(run({"help"}).code, c::kOk);
  EXPECT_NE(run({"--help"}).out.find("rarebit-cli check"), std::string::npos);
  const Result v = run({"version"});
  EXPECT_EQ(v.code, c::kOk);
  EXPECT_EQ(v.out.rfind("rarebit-cli ", 0), 0U);
  EXPECT_NE(v.out.find("Unicode"), std::string::npos);
  EXPECT_EQ(run({"frobnicate"}).code, c::kUsage);
}
