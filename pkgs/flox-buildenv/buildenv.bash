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
#     [ -m (nix|pkgdb) ] \
#     <path/to/manifest.lock>
#   -n <name> : The name of the flox environment to render.
#   -a <activation-scripts-pkg> : The store path of the activation scripts package.
#   -m (nix|pkgdb) : The method to use for realising packages. Defaults to "pkgdb".

set -eu

declare usage
usage="Usage: $0 [-x] \
  [-n <name>] \
  [-a <activation-scripts-pkg>] \
  [-m (nix|pkgdb)] \
  [-s <path/to/service-config.yaml>] \
  <path/to/manifest.lock>
-x : Enable debugging output.
-n <name> : The name of the flox environment to render.
-a <activation-scripts-pkg> : The store path of the activation scripts package.
-s <path/to/service-config.yaml> : Path to the service configuration file.
-m (nix|pkgdb) : The method to use for realising packages. Defaults to 'pkgdb'.
"

OPTSTRING="m:n:a:s:x"

declare buildMethod="${FLOX_BUILDENV_BUILD_METHOD:-pkgdb}"
declare name="${FLOX_BUILDENV_BUILD_NAME:-floxenv}"
declare activationScripts="@activationScripts@"
declare serviceConfigYamlPath=""
declare -a extraPkgdbArgs=()
declare -i debug=0
while getopts $OPTSTRING opt; do
  case $opt in
    m)
      buildMethod=$OPTARG
      ;;
    n)
      name=$OPTARG
      ;;
    a)
      activationScripts=$OPTARG
      ;;
    s)
      serviceConfigYamlPath=$OPTARG
      # extraPkgdbArgs+=(--service-config "$OPTARG")
      ;;
    x)
      debug+=1
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

# Validate arguments.
if [ $# -ne 1 ]; then
  echo $usage >&2
  exit 1
fi
if [ "$buildMethod" != "nix" ] && [ "$buildMethod" != "pkgdb" ]; then
  echo $usage >&2
  exit 1
fi

# Binaries required for the script.
declare _cp="@coreutils@/bin/cp"
declare _jq="@jq@/bin/jq"
declare _mkdir="@coreutils@/bin/mkdir"
declare _mktemp="@coreutils@/bin/mktemp"
declare _nix="@nix@/bin/nix --extra-experimental-features flakes --extra-experimental-features nix-command"
declare _nix_store="@nix@/bin/nix-store"
declare _pkgdb="@floxPkgdb@/bin/pkgdb"
declare _rm="@coreutils@/bin/rm"
declare _xargs="@findutils@/bin/xargs"

# Nicer name for referring to the manifest.
declare manifest="$1"

# Temporary directory for storing rendered files.
declare _tmpdir
_tmpdir=$($_mktemp -d --dry-run)

# Function for realising packages using legacy pkgdb. Returns the "array"
# of [one] store path to be used in the derivation's inputSrcs.
function realisePkgdb {
  # Perform the legacy pkgdb buildenv, knowing that it will materialize
  # all packages in the manifest, and return the [one] env that it creates
  # to be used in the inputSrcs array of the derivation.
  $_pkgdb buildenv "$manifest" ${extraPkgdbArgs[@]} | $_jq -r .store_path
}

# Function for realising packages using flakes. Returns the array of store
# paths to be used in the derivation's inputSrcs. We don't use this at present
# because it is significantly slower than the legacy pkgdb method, but including
# it here for reference.
function realiseFlakes {
  # Build any packages required for the environment that are not already
  # present in the store. The build-packages.jq script will output a list
  # of tuples, where the first element is the store path of the package
  # the second element is the locked flakeref for building the package,
  # and the third and fourth elements are booleans indicating whether the
  # package is unfree or broken, respectively. We then filter out the store
  # paths that already exist in the store and build the rest.
  $_jq -r --arg system @system@ -f @out@/lib/build-packages.jq "$manifest" | (
    local -a tuple
    local -a flakerefs
    local -a inputSrcs
    local impureArg=""
    while read -ra tuple; do
      inputSrcs+=("${tuple[0]}")
      if ! $_nix_store -r "${tuple[0]}" >/dev/null 2>&1; then
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
    # Actually kick off the nix build for any missing packages.
    # TODO: drop the --verbose flag below (?)
    echo "${flakerefs[@]}" | \
      $_xargs --verbose --no-run-if-empty $_nix build --no-link $impureArg
    # Return all inputSrcs store paths as a space-separated string.
    echo "${inputSrcs[@]}"
  )
}

# Function for rendering the "manifest" package from the manifest.lock file.
# This package includes all of those "activate.d" and "package-builds.d" scripts
# previously rendered to different packages, as well as the `service-config.yaml`
# file that with pkgdb is [incorrectly] being rendered to the flox environment
# package itself.
function renderManifestPackage {
  # Render the manifest package from the manifest. This is the expensive
  # part - capture the precise duration of the rendering process to get
  # an idea of how much time we can save by rendering this in Rust.
  # Make note to create the temporary directory with the same name
  # so that subsequent `nix store add-path` invocations will yield
  # the same path.
  local tmpdir="$_tmpdir/$name-manifest"
  TIMEFORMAT='It took %R seconds to render the manifest package files.'
  time {
    $_mkdir -p "$tmpdir/activate.d"
    $_cp --no-preserve=mode "$manifest" $tmpdir/manifest.lock
    $_cp --no-preserve=mode "@defaultEnvrc@" $tmpdir/activate.d/envrc
    $_jq -r '
      (.manifest.vars//{}) |
      to_entries[] |
      "export \(.key)=\"\(.value)\""
    ' $manifest >> $tmpdir/activate.d/envrc
    $_jq -r '
      if ( (.manifest.hook//{}) | has("on-activate")) then
        .manifest.hook["on-activate"]
      else empty end
    ' $manifest > $tmpdir/activate.d/hook-on-activate
    [ -s $tmpdir/activate.d/hook-on-activate ] || $_rm $tmpdir/activate.d/hook-on-activate
    for i in common bash fish tcsh zsh; do
      $_jq -r --arg section $i '
        if ( (.manifest.profile//{}) | has($section)) then
          .manifest.profile[$section]
        else empty end
      ' $manifest > $tmpdir/activate.d/profile-$i
      [ -s $tmpdir/activate.d/profile-$i ] || $_rm $tmpdir/activate.d/profile-$i
    done
    for i in $($_jq -r '(.manifest.build//{}) | keys[]' $manifest); do
      $_mkdir -p $tmpdir/package-builds.d
      $_jq -r ".manifest.build.${i}.command" $manifest > $tmpdir/package-builds.d/$i
    done
    if [ -n "$serviceConfigYamlPath" ]; then
      $_cp $serviceConfigYamlPath $tmpdir/service-config.yaml
    fi
    # The following command emits the store path of the manifest package to stdout.
  }
  echo $tmpdir
}

# main()
#
# 1. Realise all packages in the manifest.
# 2. Render the manifest package.
# 3. Calculate the output names.
# 4. Render the derivation for building the flox environment.
# 5. Build the flox environment.

# Enable debugging output if requested.
if [ $debug -gt 0 ]; then
  set -x
fi

# Realise all packages in the manifest using the selected method.
declare -a inputSrcs
TIMEFORMAT='It took %R seconds to realise the packages.'
time {
  if [ "$buildMethod" = "nix" ]; then
    inputSrcs=("$(realiseFlakes)")
  else
    inputSrcs=("$(realisePkgdb)")
  fi
}

# Render the manifest package.
declare manifestPackage
manifestPackage="$(renderManifestPackage)"

# Calculate output names.
declare outputs
TIMEFORMAT='It took %R seconds to count the outputs.'
time {
  outputs="$($_jq -r '
    (
      [ "out", "develop" ] +
      ( (.manifest.build//{}) | keys | map("build-\(.)") )
    ) | map(@json) | join(" ")
  ' $manifest)"
}

# Render derivation for building the flox environment.
TIMEFORMAT='It took %R seconds to render the flox environment outputs.'
time {
  cat <<EOF | $_nix build -L --offline --no-link --json --file - '^*'
builtins.derivation {
  name = "$name";
  system = builtins.currentSystem;
  builder = "@out@/lib/builder.pl";
  outputs = [ $outputs ];
  # Convert the supplied manifest package to a store path.
  manifestPackage = /. + $manifestPackage;
  # The following is already a storepath.
  activationScripts = builtins.storePath $activationScripts;
  # Declare all other input packages.
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
}

# Clean up temporary files.
$_rm -rf "$_tmpdir"
