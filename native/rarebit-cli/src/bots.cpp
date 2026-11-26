#include "bots.hpp"

namespace rarebit::bots {

std::vector<std::string> docker_command(const Options& options) {
  std::vector<std::string> cmd = {"docker",       "run",       "--rm",          "--read-only",
                                  "--cap-drop",   "ALL",       "--security-opt", "no-new-privileges",
                                  "--network",    options.network, "-e",        "BOTS_URL=" + options.url};
  if (!options.origin.empty()) {
    cmd.emplace_back("-e");
    cmd.push_back("BOTS_ORIGIN=" + options.origin);
  }
  cmd.push_back(options.image);
  cmd.insert(cmd.end(), options.args.begin(), options.args.end());
  return cmd;
}

}  // namespace rarebit::bots
