#
# Quick jq script to kick off builds of any missing flake outputs prior
# to rendering a flox environment.
#
# Usage:
#   sh -c "$(jq -f <this file> --arg system <system> <path/to/manifest.lock>)"
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
if $manifest."lockfile-version" != 1 then
  "ERROR: unsupported manifest schema lockfile-version: " +
  ( $manifest."lockfile-version" | tostring )
  | halt_error(1)
else . end
|

# Verify we've been called with `--arg system <system>`.
if ($ARGS.named | has("system")) then . else
  "ERROR: missing '--arg system'\n" +
  "Usage: jq -f <this file> --arg system <system> <path/to/manifest.lock>\n"
  | halt_error(1)
end
|

# Verify we've been called with a valid system.
if (($system == "x86_64-linux") or ($system == "aarch64-linux") or
    ($system == "x86_64-darwin") or ($system == "aarch64-darwin")) then . else
  "ERROR: invalid '--arg system' argument\n" +
  "Valid systems: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin\n"
  | halt_error(1)
end
|

# Generate a list of shell commands to build any missing store paths.
# TODO: group nix invocations by flake URL and free/unfree status
#       to maximize the use of the flake cache. Also investigate
#       nix plugin to allow caching of unfree flake evaluations.
$manifest.packages | map(
  select(.system == $system) |
  .locked_url as $lockedUrl |
  .attr_path as $attrPath |
  .outputs_to_install[] as $output |
  .outputs[$output] as $storePath |
  "[ -e \($storePath) ] || " +
  "nix --extra-experimental-features 'flakes nix-command' build --no-out-link '\($lockedUrl)#\($attrPath)';"
)[]
