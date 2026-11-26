// Running another program (docker) and waiting for it, on Linux, macOS and Windows.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace rarebit::process {

// The program couldn't be started (not on PATH, not executable).
class StartError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

// Runs argv[0], found on PATH, with the arguments argv[1..], the same stdin, stdout and stderr,
// and waits for it. Returns its exit code, or 128 + the signal number when a signal ended it.
// While it runs, Ctrl-C reaches the child (and ends it as it chooses); this process waits for it
// instead of ending first. Throws StartError when the program can't be started.
int run(const std::vector<std::string>& argv);

// One argument quoted for a Windows command line, so the C runtime's parser (CommandLineToArgvW)
// gives it back unchanged: quotes only when needed, backslashes doubled before a quote.
[[nodiscard]] std::string windows_quote(std::string_view arg);

}  // namespace rarebit::process
