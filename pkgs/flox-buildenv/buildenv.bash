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
_jq="@jq@/bin/jq"
_nix="@nix@/bin/nix --extra-experimental-features nix-command"

# Identify realpath of the manifest.lock passed as ARGV[0].
declare manifestRealPath
manifestRealPath="$(@coreutils@/bin/realpath "$1")"

# Build any packages required for the environment that are not already
# present in the store.
# TODO: do this in Rust.
source <($_jq -r --arg system @system@ -f @out@/lib/build-packages.jq "$manifestRealPath")

# Render the (user) activation-scripts package from the manifest.
# TODO: do this in Rust.
set -x
declare tmpdir
tmpdir=$(mktemp -d)
mkdir -p "$tmpdir/activate.d"
cp --no-preserve=mode "@defaultEnvrc@" $tmpdir/activate.d/envrc
$_jq -r '
  .manifest.vars |
  to_entries[] |
  "export \(.key)=\"\(.value)\""
' $manifestRealPath >> $tmpdir/activate.d/envrc
$_jq -r '
  if (.manifest.hook | has("on-activate")) then
    .manifest.hook["on-activate"]
  else empty end
' $manifestRealPath > $tmpdir/activate.d/hook-on-activate
[ -s $tmpdir/activate.d/hook-on-activate ] || rm $tmpdir/activate.d/hook-on-activate
for i in common bash fish tcsh zsh; do
  $_jq -r --arg section $i '
    if (.manifest.profile | has($section)) then
      .manifest.profile[$section]
    else empty end
  ' $manifestRealPath > $tmpdir/activate.d/profile-$i
  [ -s $tmpdir/activate.d/profile-$i ] || rm $tmpdir/activate.d/profile-$i
done
declare userActivationScripts
userActivationScripts="$($_nix store add-path ${tmpdir})"
rm -rf $tmpdir

# Render derivation for building the flox environment.
# TODO: do this part in Rust.
declare derivationPath
derivationPath="$( \
  $_jq -f @out@/lib/mkFloxEnvDerivation.jq \
    --arg name "$name" \
    --arg system "@system@" \
    --arg builder "@out@/lib/builder.pl" \
    --arg manifestLock "$manifestRealPath" \
    --arg activationScripts "$activationScripts" \
    --arg userActivationScripts "$userActivationScripts" \
    $manifestRealPath | \
  $_nix derivation add \
)"

# DEBUG
exit 0

# Build the flox environment.
exec $_nix build -L --no-link "$derivationPath" --json '^*'

### # TODO: let buildenv.nix parse the manifest.lock directly
### declare -a storePathArgs
### storePathArgs="$($_jq -r --arg system @system@ '.packages[] | select(.system == $system) | .outputs_to_install[] as $key | .outputs[$key] | "( storePath \(.) )"' "$manifestRealPath")"
### 
### { cat <<EOF
### with import <nixpkgs> {};
### let buildFloxEnv =
###   callPackage @out@/lib/buildenv.nix {};
### in buildFloxEnv {
###   name = "$name";
###   activationScripts = @activationScripts@;
###   manifest = builtins.toPath "$manifestRealPath";
###   paths = with builtins; [ ${storePathArgs[@]} ];
### }
### EOF
### } | exec \
###   nix --extra-experimental-features nix-command \
###     build -L --file - --json --no-link '^*'
### #} | exec nix-build --no-link -E - --attr all
