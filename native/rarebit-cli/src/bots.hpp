// `rarebit-cli bots`: runs the bots image (apps/bots) with docker, the way the local stack runs
// it (compose/compose.yaml, service `bots`): read-only, no capabilities, on the stack's network,
// reaching the game through its nginx.
#pragma once

#include <string>
#include <vector>

namespace rarebit::bots {

struct Options {
  std::string image = "rarebit-bots:dev";
  std::string network = "rarebit_default";    // the local stack's network (compose project rarebit)
  std::string url = "http://nginx:8080";      // BOTS_URL: the stack's nginx, from inside that network
  std::string origin = "http://localhost:8080";  // BOTS_ORIGIN: one the stack's game accepts
  std::vector<std::string> args;              // the mode and the bots' own options, passed on as is
};

// The docker command line: docker run --rm --read-only --cap-drop ALL --security-opt
// no-new-privileges --network <network> -e BOTS_URL=<url> [-e BOTS_ORIGIN=<origin>] <image> <args…>.
// An empty origin leaves BOTS_ORIGIN out. The bots' own --url and --origin, in args, win over the
// environment.
[[nodiscard]] std::vector<std::string> docker_command(const Options& options);

}  // namespace rarebit::bots
