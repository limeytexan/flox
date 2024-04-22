#
# Quick jq script to kick off builds of any missing flake outputs prior
# to rendering a flox environment.
# TODO: this is just a POC using the `nix profile` manifest.json format;
#       revise this for the Flox manifest.lock format.
#
# Usage:
#   sh -c "$(jq -f <this file> <path/to/manifest.json>)"
#

# Sample element:
# {
#   "active": true,
#   "attrPath": "evalCatalog.$system.stable.vim",
#   "originalUrl": "flake:nixpkgs-flox",
#   "outputs": null,
#   "priority": 5
#   "storePaths": [
#     "/nix/store/ivwgm9bdsvhnx8y7ac169cx2z82rwcla-vim-8.2.4350"
#   ],
#   "url": "github:flox/nixpkgs-flox/ef23087ad88d59f0c0bc0f05de65577009c0c676",
# }

# Load the manifest from the file passed in the first argument.
. as $manifest
|

# Verify we're talking to the expected schema version.
if $manifest.version != 1 and $manifest.version != 2 then
  error(
    "unsupported manifest schema version: " +
    ( $manifest.version | tostring )
  )
else . end
|

# Generate a list of shell commands to build any missing store paths.
# TODO: group nix invocations by flake URL and free/unfree status
#       to maximize the use of the flake cache. Also investigate
#       nix plugin to allow caching of unfree flake evaluations.
$manifest.elements | map(
  .url as $url |
  .attrPath as $attrPath |
  .storePaths | map(
    ( "-e " + . )
  ) | join(" -a ") as $conditional
  | "[ " + $conditional + " ] || " +
    "nix build --no-out-link '\($url)#\($attrPath)';"
)[]
