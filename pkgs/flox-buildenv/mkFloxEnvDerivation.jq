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

# Verify we're talking to the expected schema version.
if ."lockfile-version" != 1 then
  "ERROR: unsupported manifest schema lockfile-version: " +
  ( ."lockfile-version" | tostring )
  | halt_error(1)
else . end
|

# Function for emitting a package set in the format consumed by
# the builder.pl script.
def packagesToPkgs($_packages):
  $_packages | map(
    .outputs_to_install[] as $output |
    .outputs[$output] as $storePath |
    {
      paths: [ $storePath ],
      priority: .priority
    }
  );

# We can have nice names for things.
.packages as $packages |
.manifest as $manifest |
$manifest.install as $install |
$manifest.build as $builds |
( $builds | keys ) as $buildNames |

# Construct an array containing the Flox activation-scripts packages.
[
  {
    outputs_to_install: [ "out" ],
    outputs: {
      "out": $activationScripts
    },
    priority: 1
  },
  {
    outputs_to_install: [ "out" ],
    outputs: {
      "out": $userActivationScripts
    },
    priority: 1
  }
] as $activationScriptsPackages
|

# Filter system-specific outputs to include in the "out" output.
( $packages | map( select(.system == $system) ) ) as $outPackages
|

# Define the "develop" output as all packages with activation scripts included.
( $outPackages + $activationScriptsPackages ) as $developPackages
|

# Filter only packages included in the "toplevel" group for use in builds.
( $outPackages | map( select(.group == "toplevel") ) ) as $toplevelPackages
|

# Iterate over the list of builds, filtering from the "toplevel" group
# just those packages included in the "packages" attribute if defined,
# otherwise just including the entirety of the "toplevel" group.
( $builds | to_entries[] as $build |

  # Come up with the list of candidate package installation names
  # to be installed.
  (
    if ($build.value | has("packages")) then
      $build.value.packages
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

  # Filter packages found in the "toplevel" pkg-group to include only
  # those packages found in `$buildPackageAttrPaths`.
  $toplevelPackages | map(
    select(.attr_path | in($buildPackageAttrPaths))
  ) as $buildPackages |

  # Represent the result as a hash keyed by the build name.
  {
    "\($build.key)": ( $buildPackages + $activationScriptsPackages )
  }
) as $buildPackagesHash
|

# Construct each of the "pkgs" environment variables consumed by the
# builder.pl script.
(
  {
    "pkgs": packagesToPkgs($outPackages),
    "developPkgs": packagesToPkgs($developPackages),
  } * (
    $buildPackagesHash | with_entries(
      .key += "Pkgs" |
      .value = packagesToPkgs(.value)
    )
  )
) as $envPkgSets
|

# Identify all build runtime closures to be rendered and include them
# in the list of outputs to render. List all output names as keys in a
# hash with all empty values as Nix will fill in that part.
{
  "outputs": (
    {
      "out": {},
      "develop": {}
    } * (
      $builds | with_entries(.value = {})
    )
  )
} as $outputs
|

# The "inputSrcs" value is just a list of storepaths to be mapped into
# the build "container", and it's safe to just list all storepaths
# encountered in $packages.
(
  $outPackages | map(
    .outputs_to_install[] as $output |
    .outputs[$output]
  )
) as $inputSrcs
|

debug($envPkgSets) |

{
  "name": $name,
  "system": $system,
  "outputs": $outputs,
  "inputSrcs": $inputSrcs,
  "builder": "/nix/store/0",
  "env": $envPkgSets
}
