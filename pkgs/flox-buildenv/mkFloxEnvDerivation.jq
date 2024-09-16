#
# jq script to generate a Nix derivation for building a Flox environment from
# a manifest.lock file.
#
# This script emits the [experimental] derivation JSON format as described in:
#   https://github.com/NixOS/nix/blob/master/doc/manual/src/protocols/json/derivation.md
#

# Sample manifest.lock:
# {
#   "lockfile-version": 1,
#   "manifest": {
#     "build": {
#       "foo": {
#         "packages": [ "curl" ],
#         ...
#       }
#     },
#     "install": {
#       "curl": {
#         "pkg-path": "curl"
#       },
#       "xeyes": {
#         "pkg-path": "xorg.xeyes"
#       }
#     },
#     "version": 1,
#     ...
#   },
#   "packages": [
#     {
#       "attr_path": "curl",
#       "group": "toplevel",
#       "outputs": {
#         "bin": "/nix/store/1033k8sfipzk1ly7igmawdra7lg348wb-curl-8.7.1-bin",
#         "dev": "/nix/store/fwbjf1ikz055flksk2isiam4ajl0rpa5-curl-8.7.1-dev",
#         "devdoc": "/nix/store/yvgigsmfgxx4raiqi7qfn1aygf3fp5lj-curl-8.7.1-devdoc",
#         "man": "/nix/store/lqb2rgnwxqvqppgda0p9lnw02ddzwiyc-curl-8.7.1-man",
#         "out": "/nix/store/37ydms17yxwi5y5rck08c93jad1rmrn8-curl-8.7.1"
#       },
#       "outputs_to_install": [
#         "bin",
#         "man"
#       ],
#       "priority": 5,
#       "system": "aarch64-darwin",
#       ...
#     },
#     {
#       "attr_path": "xorg.xeyes",
#       "group": "toplevel",
#       "outputs": {
#         "out": "/nix/store/zl1d3gmhvpb1s6jdbqxmy3y1rflrr71v-xeyes-1.3.0"
#       },
#       "outputs_to_install": [
#         "out"
#       ],
#       "priority": 5,
#       "system": "x86_64-linux",
#       ...
#     }
#   ]
# }

# Example output for the "foo" build:
# ...

( "Usage: jq -f <this file> " +
    "--arg name <name> " +
    "--arg system <system> " +
    "--arg build <name> " +
    "--arg activationScripts <path> " +
    "--arg userActivationScripts <path> " +
    "<path/to/manifest.lock>\n" +
  "Valid systems: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin\n" ) as $usage
|

# Verify we've been called with `--arg system <system>`.
if ($ARGS.named | has("system")) then . else
  "ERROR: missing '--arg system'\n" + $usage
  | halt_error(1)
end
|

# Verify we've been called with a valid system.
if (($system == "x86_64-linux") or ($system == "aarch64-linux") or
    ($system == "x86_64-darwin") or ($system == "aarch64-darwin")) then . else
  "ERROR: invalid '--arg system' argument\n" + $usage
  | halt_error(1)
end
|

# Verify we've been called with `--arg activationScripts <pkg>`.
if ($ARGS.named | has("activationScripts")) then . else
  "ERROR: missing '--arg activationScripts'\n" + $usage
  | halt_error(1)
end
|

# Verify we've been called with `--arg userActivationScripts <pkg>`.
if ($ARGS.named | has("userActivationScripts")) then . else
  "ERROR: missing '--arg userActivationScripts'\n" + $usage
  | halt_error(1)
end
|

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

# We can have nice names for things.
.packages as $packages |
.manifest as $manifest |
$manifest.install as $install |

.
