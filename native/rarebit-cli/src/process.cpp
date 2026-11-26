#include "process.hpp"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstring>

extern char** environ;  // NOLINT: POSIX
#endif

namespace rarebit::process {

std::string windows_quote(std::string_view arg) {
  if (!arg.empty() && arg.find_first_of(" \t\n\v\"") == std::string_view::npos) {
    return std::string(arg);
  }
  std::string out = "\"";
  for (std::size_t i = 0;; ++i) {
    std::size_t backslashes = 0;
    while (i < arg.size() && arg[i] == '\\') {
      ++i;
      ++backslashes;
    }
    if (i == arg.size()) {
      out.append(backslashes * 2, '\\');  // before the closing quote, every backslash doubles
      break;
    }
    if (arg[i] == '"') {
      out.append(backslashes * 2 + 1, '\\');
      out.push_back('"');
    } else {
      out.append(backslashes, '\\');
      out.push_back(arg[i]);
    }
  }
  out.push_back('"');
  return out;
}

#ifdef _WIN32

namespace {

std::wstring widen(const std::string& s) {
  if (s.empty()) {
    return {};
  }
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
  if (n <= 0) {
    throw StartError("an argument isn't valid UTF-8");
  }
  std::wstring out(static_cast<std::size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

// Ctrl-C reaches every process on the console; the child decides what it means. This process
// keeps waiting for it. (A handler that returns TRUE isn't inherited, unlike ignoring Ctrl-C.)
BOOL WINAPI keep_waiting(DWORD) { return TRUE; }

}  // namespace

int run(const std::vector<std::string>& argv) {
  if (argv.empty()) {
    throw StartError("nothing to run");
  }
  std::string line;
  for (const auto& a : argv) {
    if (!line.empty()) {
      line.push_back(' ');
    }
    line += windows_quote(a);
  }
  std::wstring wline = widen(line);
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};
  if (!CreateProcessW(nullptr, wline.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
    throw StartError("can't start " + argv[0] + " (Windows error " + std::to_string(GetLastError()) + ")");
  }
  SetConsoleCtrlHandler(keep_waiting, TRUE);
  WaitForSingleObject(pi.hProcess, INFINITE);
  SetConsoleCtrlHandler(keep_waiting, FALSE);
  DWORD code = 1;
  GetExitCodeProcess(pi.hProcess, &code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return static_cast<int>(code);
}

#else

namespace {

volatile std::sig_atomic_t g_child = 0;

// SIGTERM to this process goes on to the child, which ends as it chooses (the bots finish their
// games); this process then reports its exit code.
extern "C" void forward_signal(int sig) {
  if (g_child > 0) {
    kill(static_cast<pid_t>(g_child), sig);
  }
}

}  // namespace

int run(const std::vector<std::string>& argv) {
  if (argv.empty()) {
    throw StartError("nothing to run");
  }
  std::vector<std::string> args = argv;
  std::vector<char*> cargs;
  cargs.reserve(args.size() + 1);
  for (auto& a : args) {
    cargs.push_back(a.data());
  }
  cargs.push_back(nullptr);

  // As system() does: Ctrl-C and Ctrl-\ reach the whole foreground process group, so the child
  // gets them; this process ignores them and waits. The child starts with the default actions.
  struct sigaction ignore {};
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  struct sigaction forward {};
  forward.sa_handler = forward_signal;
  sigemptyset(&forward.sa_mask);
  struct sigaction old_int {};
  struct sigaction old_quit {};
  struct sigaction old_term {};
  sigaction(SIGINT, &ignore, &old_int);
  sigaction(SIGQUIT, &ignore, &old_quit);
  sigaction(SIGTERM, &forward, &old_term);

  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  sigset_t defaults;
  sigemptyset(&defaults);
  sigaddset(&defaults, SIGINT);
  sigaddset(&defaults, SIGQUIT);
  sigaddset(&defaults, SIGTERM);
  posix_spawnattr_setsigdefault(&attr, &defaults);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF);

  pid_t pid = 0;
  const int err = posix_spawnp(&pid, cargs[0], nullptr, &attr, cargs.data(), environ);
  posix_spawnattr_destroy(&attr);
  int status = 0;
  if (err == 0) {
    g_child = static_cast<std::sig_atomic_t>(pid);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    g_child = 0;
  }
  sigaction(SIGINT, &old_int, nullptr);
  sigaction(SIGQUIT, &old_quit, nullptr);
  sigaction(SIGTERM, &old_term, nullptr);
  if (err != 0) {
    throw StartError("can't start " + argv[0] + ": " + std::strerror(err));
  }
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return 128 + WTERMSIG(status);
  }
  return 1;
}

#endif

}  // namespace rarebit::process
