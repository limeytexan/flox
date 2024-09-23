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

# Binaries required for the build.
_cp="@coreutils@/bin/cp"
_jq="@jq@/bin/jq"
_mktemp="@coreutils@/bin/mktemp"
_nix="@nix@/bin/nix --extra-experimental-features flakes --extra-experimental-features nix-command"
_rm="@coreutils@/bin/rm"
_xargs="@findutils@/bin/xargs"

# Nicer name for referring to the manifest.
declare manifest="$1"

# Build any packages required for the environment that are not already
# present in the store. The build-packages.jq script will output a list
# of tuples, where the first element is the store path of the package
# and the second element is the locked flakeref for building the package.
# We then filter out the store paths that already exist in the store with
# the `while` loop and build the rest.
# TODO: do this in Rust.
$_jq -r --arg system @system@ -f @out@/lib/build-packages.jq "$manifest" | (

  # The remainder of this script is executed in a subshell so that variables
  # derived from the output of the jq script above can be used for subsequent
  # nix invocations.
  declare -a tuple
  declare -a inputSrcs
  declare -a flakerefs
  declare impureArg=""
  while read -ra tuple; do
    inputSrcs+=("${tuple[0]}")
    if [ ! -e "${tuple[0]}" ]; then
      flakerefs+=("${tuple[1]}")
      if [ "${tuple[2]}" = "true" ]; then
        export NIXPKGS_ALLOW_UNFREE=1
        impureArg="--impure"
      fi
      if [ "${tuple[3]}" = "true" ]; then
        export NIXPKGS_ALLOW_BROKEN=1
        impureArg="--impure"
      fi
    fi
  done
  # TODO: drop the --verbose flag below (?)
  echo "${flakerefs[@]}" | \
    $_xargs --verbose --no-run-if-empty $_nix build --no-link $impureArg

  # Render the (user) activation-scripts package from the manifest.
  # Make note to create the temporary directory with the same name
  # so that subsequent `nix store add-path` invocations will yield
  # the same path.
  # TODO: do this in Rust.
  declare tmpdir
  _tmpdir=$($_mktemp -d)
  declare tmpdir="$_tmpdir/$name"
  mkdir -p "$tmpdir/activate.d"
  $_cp --no-preserve=mode "@defaultEnvrc@" $tmpdir/activate.d/envrc
  $_jq -r '
    .manifest.vars |
    to_entries[] |
    "export \(.key)=\"\(.value)\""
  ' $manifest >> $tmpdir/activate.d/envrc
  $_jq -r '
    if (.manifest.hook | has("on-activate")) then
      .manifest.hook["on-activate"]
    else empty end
  ' $manifest > $tmpdir/activate.d/hook-on-activate
  [ -s $tmpdir/activate.d/hook-on-activate ] || $_rm $tmpdir/activate.d/hook-on-activate
  for i in common bash fish tcsh zsh; do
    $_jq -r --arg section $i '
      if (.manifest.profile | has($section)) then
        .manifest.profile[$section]
      else empty end
    ' $manifest > $tmpdir/activate.d/profile-$i
    [ -s $tmpdir/activate.d/profile-$i ] || $_rm $tmpdir/activate.d/profile-$i
  done
  declare userActivationScripts
  userActivationScripts="$($_nix store add-path ${tmpdir})"
  $_rm -rf $_tmpdir

  # Calculate output names.
  declare outputs
  outputs="$($_jq -r '( [ "out", "develop" ] + ( .manifest.build | keys | map("build-\(.)") ) ) | map(@json) | join(" ")' $manifest)"

  # Render derivation for building the flox environment.
  # TODO: do this part in Rust.
  ( cat <<EOF
builtins.derivation {
  name = "$name";
  system = builtins.currentSystem;
  builder = "@out@/lib/builder.pl";
  outputs = [ $outputs ];
  # Convert the supplied manifest to a store path.
  manifest = /. + $manifest;
  # Both of the following are storepaths.
  activationScripts = $activationScripts;
  userActivationScripts = $userActivationScripts;
  # Declare all inputs.
  inputSrcs = map (x: builtins.storePath x) [ @out@ ${inputSrcs[@]} ];
  # If the special attribute __structuredAttrs is set to true, the
  # other derivation attributes are serialised in JSON format and
  # made available to the builder via the file .attrs.json in the
  # builder’s temporary directory. This obviates the need for
  # passAsFile since JSON files have no size restrictions, unlike
  # process environments.
  __structuredAttrs = true;
}
EOF
  ) | exec $_nix build -L --offline --no-link --json --file - '^*'

)
