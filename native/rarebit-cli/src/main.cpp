// rarebit-cli's entry point: the arguments as UTF-8, then cli::run.
#include <iostream>
#include <string>
#include <vector>

#include "cli.hpp"
#include "process.hpp"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

namespace {

// Windows passes the command line as UTF-16; the rest of the program works in UTF-8.
std::string narrow(const wchar_t* w) {
  const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) {
    return {};
  }
  std::string out(static_cast<std::size_t>(n - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), n, nullptr, nullptr);
  return out;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleOutputCP(CP_UTF8);  // Hebrew output on the console
  std::vector<std::string> args;
  for (int i = 1; i < argc; ++i) {
    args.push_back(narrow(argv[i]));
  }
  return rarebit::cli::run(args, std::cout, std::cerr, rarebit::process::run);
}

#else

int main(int argc, char** argv) {
  const std::vector<std::string> args(argv + 1, argv + argc);
  return rarebit::cli::run(args, std::cout, std::cerr, rarebit::process::run);
}

#endif
