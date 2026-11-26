// rarebit-cli's commands, as a function of the arguments, so the tests can run them directly.
#pragma once

#include <functional>
#include <ostream>
#include <string>
#include <vector>

namespace rarebit::cli {

// Exit codes.
inline constexpr int kOk = 0;        // check: the answer is valid
inline constexpr int kNotValid = 1;  // check: invalid or unknown
inline constexpr int kUsage = 2;     // bad arguments, an unknown category or letter
inline constexpr int kData = 3;      // a word list can't be read or breaks the data rules
inline constexpr int kNoDocker = 127;

// Starts a program and returns its exit code (process::run, or a fake in tests).
using Runner = std::function<int(const std::vector<std::string>&)>;

// Runs one command. args excludes the program name.
int run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err, const Runner& runner);

}  // namespace rarebit::cli
