#
# jq script to generate a "pkgs" format JSON blob for each manifest
# build runtime output. This blob is then consumed by `builder.pl`
# to construct an environment package of symlinks referring to the
# the packages named in the `manifest.build.<name>.packages` array,
# or the `toplevel` group packages if not specified, plus the
# supplied `activationScripts` and `userActivationScripts` packages.
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
# [
#   {
#     "paths": [
#       "/nix/store/1033k8sfipzk1ly7igmawdra7lg348wb-curl-8.7.1-bin"
#     ],
#     "priority": 5
#   },
#   {
#     "paths": [
#       "/nix/store/lqb2rgnwxqvqppgda0p9lnw02ddzwiyc-curl-8.7.1-man"
#     ],
#     "priority": 5
#   }
#   {
#     "paths": [
#       "/nix/store/zc3y7cr5b073n8d7ma2k1rr7b28a9qlw-w4dnl8i62baxgqz6y1qhqb60dk6qn761-flox-activation-scripts"
#     ],
#     "priority": 1
#   }
# ]

( "Usage: jq -f <this file> " +
    "--arg system <system> " +
    "--arg build <name> " +
    "--arg activationScripts <path> " +
    "--arg userActivationScripts <path> " +
    "<path/to/manifest.lock>\n" +
  "Valid systems: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin\n" ) as $usage
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

# Verify we've been called with `--arg build <name>`.
if ($ARGS.named | has("build")) then . else
  "ERROR: missing '--arg build'\n" + $usage
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

# We can have nice names for things.
.packages as $packages |
.manifest as $manifest |
$manifest.install as $install |

# Verify that the named build is found.
if ($manifest | has("build")) then . else
  "ERROR: cannot find manifest.build section in manifest\n" + $usage
  | halt_error(1)
end
|

# We can have more nice names.
$manifest.build as $builds |

# Verify that the requested build is found. Recall that $build
# is the name of the build as passed in the `--arg build` argument.
if ($builds | has($build)) then . else
  "ERROR: cannot find build data for \"\($build)\" in manifest\n" + $usage
  | halt_error(1)
end
|

# We can have even more nice names.
$builds[$build] as $theBuild |

# Come up with the list of candidate package attr-paths to consider.
(
  if ($theBuild | has("packages")) then
    $theBuild.packages
  else
    ( $install | keys )
  end
) as $buildPackageNames |

# Derive the corresponding package attr-paths.
(
  reduce $buildPackageNames[] as $name (
    {};
    if ($install | has($name)) then (
      .[$install[$name]["pkg-path"]] = 1
    ) else . end
  )
) as $buildPackageAttrPaths |

# Filter the system-specific packages found in the "toplevel" pkg-group
# to include only those packages found in `$buildPackageAttrPaths`.
$packages | map(
  select(.system == $system) |
  select(.group == "toplevel") |
  select(.attr_path | in($buildPackageAttrPaths)) |
  .outputs_to_install[] as $output |
  .outputs[$output] as $storePath |
  {
    paths: [ $storePath ],
    priority: .priority
  }
) +
# Always include the activation-scripts package.
[
  {
    paths: [ $activationScripts ],
    priority: 1
  },
  {
    paths: [ $userActivationScripts ],
    priority: 1
  }
]
