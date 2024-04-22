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
#     [ -i <interpreter> ] \
#     <path/to/manifest.json>

set -e

export PATH=@nix@/bin:"$PATH"

OPTSTRING="n:t:"

declare name="floxenv"
declare interpreter="@interpreter@"
while getopts $OPTSTRING opt; do
  case $opt in
    n)
      name=$OPTARG
      ;;
    i)
      interpreter=$OPTARG
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
  echo "Usage: $0 [-n <name>] [-i <interpreter>] <path/to/manifest.json>" >&2
  exit 1
fi

# Parse the manifest.json passed as ARGV[0]
declare rp
rp="$(@coreutils@/bin/realpath "$1")"

# Render any missing packages.
source <(@jq@/bin/jq -r -f @out@/lib/build-packages.jq "$rp")

# TODO: let buildenv.nix parse the manifest.json directly
declare -a storePathArgs
storePathArgs="$(@jq@/bin/jq -r '.elements[].storePaths[] | "( storePath \(.) )"' "$rp")"

{ cat <<EOF
with import <nixpkgs> {};
let buildFloxEnv =
  callPackage @out@/lib/buildenv.nix {};
in buildFloxEnv {
  name = "$name";
  interpreter = @interpreter@;
  manifest = builtins.toPath "$rp";
  paths = with builtins; [ ${storePathArgs[@]} ];
}
EOF
} | exec nix-build -E - --attr all
