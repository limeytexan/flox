#
# Simple nix wrapper to render a flox environment using buildenv.nix.
#
# A flox environment differs from the normal nix buildEnv in that it
# renders an extra tree of symbolic links to the ".develop" subdirectory
# containing the deep recursively-linked propagaged-user-env-packages
# of all packages contained within the environment.
#
# Usage:
#   buildenv \
#     [ -n <name> ] \
#     [ -a <activation-scripts-pkg> ] \
#     <path/to/manifest.lock>

set -eu

export PATH=@nix@/bin:"$PATH"

OPTSTRING="n:a:"

declare name="floxenv"
declare activationScripts="@activationScripts@"
while getopts $OPTSTRING opt; do
  case $opt in
    n)
      name=$OPTARG
      ;;
    a)
      activationScripts=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))

if [ $# -ne 1 ]; then
  echo "Usage: $0 [-n <name>] [-a <activation-scripts-pkg>] <path/to/manifest.lock>" >&2
  exit 1
fi

# Parse the manifest.lock passed as ARGV[0]
declare rp
rp="$(@coreutils@/bin/realpath "$1")"

# Render any missing packages.
source <(@jq@/bin/jq -r --arg system @system@ -f @out@/lib/build-packages.jq "$rp")

# TODO: let buildenv.nix parse the manifest.lock directly
declare -a storePathArgs
storePathArgs="$(@jq@/bin/jq -r --arg system @system@ '.packages[] | select(.system == $system) | .outputs_to_install[] as $key | .outputs[$key] | "( storePath \(.) )"' "$rp")"

{ cat <<EOF
with import <nixpkgs> {};
let buildFloxEnv =
  callPackage @out@/lib/buildenv.nix {};
in buildFloxEnv {
  name = "$name";
  activationScripts = @activationScripts@;
  manifest = builtins.toPath "$rp";
  paths = with builtins; [ ${storePathArgs[@]} ];
}
EOF
} | exec \
  nix --extra-experimental-features nix-command \
    build -L --file - --json --no-link '^*'
