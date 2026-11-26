#include "cli.hpp"

#include <filesystem>
#include <optional>
#include <string_view>

#include <hebrew_normalize/hebrew_normalize.hpp>

#include "bots.hpp"
#include "json.hpp"
#include "process.hpp"
#include "utf8.hpp"
#include "wordlist.hpp"

#ifndef RAREBIT_CLI_VERSION
#define RAREBIT_CLI_VERSION "dev"
#endif

namespace rarebit::cli {

namespace {

constexpr std::string_view kUsageText =
    R"(rarebit-cli: answers, normalization and bots for Rarebit

  rarebit-cli check [--data DIR] [--json] <category> <letter> <answer>
      Judge an answer the way the validator does, offline, from the word lists in DIR
      (default: data/categories). Exit 0 valid, 1 invalid or unknown.
  rarebit-cli normalize [--json] <text>
      Show the comparison key and the spelling key the matching uses.
  rarebit-cli bots [--image IMAGE] [--network NETWORK] [--url URL] [--origin ORIGIN]
                   [--dry-run] <mode> [bots options...]
      Run the bots image with docker: by default on the local stack (make up), through its
      nginx. <mode> and what follows go to the bots as is (apps/bots/README.md).
  rarebit-cli version

Exit codes: 0 ok, 1 not valid (check), 2 bad arguments, 3 unreadable word lists,
127 docker not found; bots: the bots' own exit code.
)";

// Splits args into options (--name value or --name=value; flags take no value) and positional
// arguments. Stops reading options at "--" or, when stop_at_positional, at the first positional
// argument (everything from it on is positional).
struct Parsed {
  std::vector<std::pair<std::string, std::string>> options;
  std::vector<std::string> positional;
};

std::optional<Parsed> parse(const std::vector<std::string>& args, std::size_t from,
                            const std::vector<std::string_view>& with_value,
                            const std::vector<std::string_view>& flags, bool stop_at_positional,
                            std::ostream& err) {
  Parsed p;
  bool options_done = false;
  for (std::size_t i = from; i < args.size(); ++i) {
    const std::string& a = args[i];
    if (options_done || a.size() < 2 || a[0] != '-' || a[1] != '-') {
      p.positional.push_back(a);
      if (stop_at_positional) {
        options_done = true;
      }
      continue;
    }
    if (a == "--") {
      options_done = true;
      continue;
    }
    const auto eq = a.find('=');
    const std::string name = a.substr(0, eq);
    const auto is = [&name](const std::vector<std::string_view>& names) {
      for (auto n : names) {
        if (n == name) {
          return true;
        }
      }
      return false;
    };
    if (is(flags) && eq == std::string::npos) {
      p.options.emplace_back(name, "");
    } else if (is(with_value)) {
      if (eq != std::string::npos) {
        p.options.emplace_back(name, a.substr(eq + 1));
      } else if (i + 1 < args.size()) {
        p.options.emplace_back(name, args[++i]);
      } else {
        err << "rarebit-cli: " << name << " needs a value\n";
        return std::nullopt;
      }
    } else {
      err << "rarebit-cli: unknown option " << a << "\n";
      return std::nullopt;
    }
  }
  return p;
}

std::string describe(const wordlist::Outcome& o, std::string_view letter) {
  if (o.result == "valid") {
    std::string how = o.match == "exact" ? "exact match with" : o.match == "variant" ? "spelling variant of" : "one-letter typo of";
    return "valid: " + how + " \"" + o.entry + "\"";
  }
  if (o.result == "unknown") {
    return "unknown: not in the word lists; in a game, the room votes on it";
  }
  if (o.reason == "too_long") {
    return "invalid: longer than " + std::to_string(wordlist::kMaxAnswerRunes) + " characters";
  }
  if (o.reason == "empty") {
    return "invalid: no letters";
  }
  return "invalid: doesn't start with " + std::string(letter);
}

int run_check(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
  const auto p = parse(args, 1, {"--data"}, {"--json"}, false, err);
  if (!p) {
    return kUsage;
  }
  if (p->positional.size() != 3) {
    err << "rarebit-cli: check needs <category> <letter> <answer>\n";
    return kUsage;
  }
  std::filesystem::path dir = "data/categories";
  bool as_json = false;
  for (const auto& [name, value] : p->options) {
    if (name == "--data") {
      dir = value;
    } else {
      as_json = true;
    }
  }
  const std::string& id = p->positional[0];
  const std::string& letter = p->positional[1];
  const std::string& answer = p->positional[2];
  try {
    const wordlist::Category category = wordlist::load(dir, id);
    const wordlist::Outcome o = wordlist::check(category, letter, answer);
    if (as_json) {
      out << wordlist::to_json(o) << "\n";
    } else {
      out << describe(o, letter) << "\n";
      if (!o.key.empty()) {
        out << "key: " << o.key << "\n";
      }
    }
    return o.result == "valid" ? kOk : kNotValid;
  } catch (const wordlist::RequestError& e) {
    if (std::string_view(e.what()) == "unknown category") {
      err << "rarebit-cli: unknown category \"" << id << "\": no " << id << ".json in " << dir.string() << "\n";
    } else {
      err << "rarebit-cli: " << e.what() << "\n";
    }
    return kUsage;
  } catch (const wordlist::DataError& e) {
    err << "rarebit-cli: " << e.what() << "\n";
    return kData;
  }
}

int run_normalize(const std::vector<std::string>& args, std::ostream& out, std::ostream& err) {
  const auto p = parse(args, 1, {}, {"--json"}, false, err);
  if (!p) {
    return kUsage;
  }
  if (p->positional.size() != 1) {
    err << "rarebit-cli: normalize needs one <text>\n";
    return kUsage;
  }
  const std::string& text = p->positional[0];
  const std::string key = hebrew_normalize::normalize(text);
  const std::string spelling = hebrew_normalize::spelling_key(text);
  const std::size_t letters = utf8::rune_count(key);
  if (!p->options.empty()) {
    out << "{\"key\":" << json::quote(key) << ",\"spelling_key\":" << json::quote(spelling)
        << ",\"letters\":" << letters << "}\n";
  } else {
    out << "key: " << key << "\nspelling key: " << spelling << "\nletters: " << letters << "\n";
  }
  return kOk;
}

int run_bots(const std::vector<std::string>& args, std::ostream& out, std::ostream& err, const Runner& runner) {
  const auto p = parse(args, 1, {"--image", "--network", "--url", "--origin"}, {"--dry-run"}, true, err);
  if (!p) {
    return kUsage;
  }
  if (p->positional.empty()) {
    err << "rarebit-cli: bots needs a <mode>: synthetic, load or observe\n";
    return kUsage;
  }
  bots::Options options;
  bool dry_run = false;
  for (const auto& [name, value] : p->options) {
    if (name == "--image") {
      options.image = value;
    } else if (name == "--network") {
      options.network = value;
    } else if (name == "--url") {
      options.url = value;
    } else if (name == "--origin") {
      options.origin = value;
    } else {
      dry_run = true;
    }
  }
  options.args = p->positional;
  const std::vector<std::string> cmd = bots::docker_command(options);
  if (dry_run) {
    for (std::size_t i = 0; i < cmd.size(); ++i) {
      out << (i == 0 ? "" : " ") << cmd[i];
    }
    out << "\n";
    return kOk;
  }
  try {
    return runner(cmd);
  } catch (const process::StartError& e) {
    err << "rarebit-cli: " << e.what() << " (is Docker installed and on PATH?)\n";
    return kNoDocker;
  }
}

}  // namespace

int run(const std::vector<std::string>& args, std::ostream& out, std::ostream& err, const Runner& runner) {
  if (args.empty()) {
    err << kUsageText;
    return kUsage;
  }
  const std::string& command = args[0];
  if (command == "check") {
    return run_check(args, out, err);
  }
  if (command == "normalize") {
    return run_normalize(args, out, err);
  }
  if (command == "bots") {
    return run_bots(args, out, err, runner);
  }
  if (command == "version" || command == "--version") {
    out << "rarebit-cli " << RAREBIT_CLI_VERSION << " (hebrew-normalize " << hebrew_normalize::version()
        << ", Unicode " << hebrew_normalize::unicode_version() << ")\n";
    return kOk;
  }
  if (command == "help" || command == "--help" || command == "-h") {
    out << kUsageText;
    return kOk;
  }
  err << "rarebit-cli: unknown command \"" << command << "\"\n\n" << kUsageText;
  return kUsage;
}

}  // namespace rarebit::cli
