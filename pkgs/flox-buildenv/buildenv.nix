# buildEnv creates a tree of symlinks to the specified paths.  This is
# a fork of the hardcoded buildEnv in the Nix distribution.

{ buildPackages, runCommand, lib, substituteAll, targetPlatform }:

let
  builder = substituteAll {
    src = ./builder.pl;
    inherit (builtins) storeDir;
  };
  build_closures_jq = ./build-closures.jq;
in

lib.makeOverridable
({ name

, # The path to the flox "activation-scripts" package.
  activationScripts

, # The manifest file (if any).  A symlink $out/manifest will be
  # created to it.
  manifest ? ""

, # The paths to symlink.
  paths

, # Whether to ignore collisions or abort.
  ignoreCollisions ? false

, # If there is a collision, check whether the contents and permissions match
  # and only if not, throw a collision error.
  checkCollisionContents ? true

, # The paths (relative to each element of `paths') that we want to
  # symlink (e.g., ["/bin"]).  Any file not inside any of the
  # directories in the list is not symlinked.
  pathsToLink ? ["/"]

, # The package outputs to include. By default, only the default
  # output is included.
  extraOutputsToInstall ? []

, # Root the result in directory "$out${extraPrefix}", e.g. "/share".
  extraPrefix ? ""

, # Shell commands to run after building the symlink tree.
  postBuild ? ""

# Additional inputs
, nativeBuildInputs ? [] # Handy e.g. if using makeWrapper in `postBuild`.
, buildInputs ? []

, passthru ? {}
, meta ? {}
}:

let
    # Unlike the nixpkgs buildEnv, the Flox one has multiple outputs,
    # the usual builtins.buildenv() output, a "develop" output, and
    # a runtime closure for each of the manifest builds.
    manifestBuilds = if manifest == "" then [] else (
      let _manifest = builtins.fromJSON (builtins.readFile manifest);
      in builtins.attrNames _manifest.manifest.build
    );

in
runCommand name
  rec {
    inherit manifest ignoreCollisions checkCollisionContents passthru
            meta pathsToLink extraPrefix postBuild
            nativeBuildInputs buildInputs;

    outputs = ["out" "develop"] ++ manifestBuilds;

    pkgs = builtins.toJSON (map (drv: {
      paths =
        # First add the usual output(s): respect if user has chosen explicitly,
        # and otherwise use `meta.outputsToInstall`. The attribute is guaranteed
        # to exist in mkDerivation-created cases. The other cases (e.g. runCommand)
        # aren't expected to have multiple outputs.
        (if (! drv ? outputSpecified || ! drv.outputSpecified)
            && drv.meta.outputsToInstall or null != null
          then map (outName: drv.${outName}) drv.meta.outputsToInstall
          else [ drv ])
        # Add any extra outputs specified by the caller of `buildEnv`.
        ++ lib.filter (p: p!=null)
          (builtins.map (outName: drv.${outName} or null) extraOutputsToInstall);
      priority = drv.meta.priority or 5;
    }) paths);

    # The develop output adds a single package, activation-scripts.
    # I'm sure a Nix lang expert could make this more elegant
    # by factoring out the paths assignment from above but this
    # works for a demo.
    developPkgs = builtins.toJSON ((map (drv: {
      paths =
        # First add the usual output(s): respect if user has chosen explicitly,
        # and otherwise use `meta.outputsToInstall`. The attribute is guaranteed
        # to exist in mkDerivation-created cases. The other cases (e.g. runCommand)
        # aren't expected to have multiple outputs.
        (
          if
            (! drv ? outputSpecified || ! drv.outputSpecified)
            && drv.meta.outputsToInstall or null != null
          then map (outName: drv.${outName}) drv.meta.outputsToInstall
          else [drv]
        )
        # Add any extra outputs specified by the caller of `buildEnv`.
        ++ lib.filter (p: p != null)
          (builtins.map (outName: drv.${outName} or null) extraOutputsToInstall);
      priority = drv.meta.priority or 5;
    }) paths) ++ [
      {
        paths = [activationScripts];
        priority = 1;
      }
    ]);

    preferLocalBuild = true;
    allowSubstitutes = false;

    # Nix "*Path" environment variables are automatically created by
    # way of the derivation `passAsFile` attribute as described in:
    #
    # https://nix.dev/manual/nix/2.18/language/advanced-attributes#adv-attr-passAsFile
    #
    # The following causes `pkgsPath` and `developPkgsPath` to be set.
    passAsFile = [ "pkgs" "developPkgs" ];
  }
  ''
    ${buildPackages.perl}/bin/perl -w ${builder}

    # The `builder.pl` script expects to receive the list of packages by
    # way of one of the `pkgsPath` or `pkgs` environment variables. Explicitly
    # set these variables when building the "develop" output.
    if [ -n "$developPkgsPath" ]; then
      out=$develop pkgsPath=$developPkgsPath FLOX_RECURSIVE_LINK=1 \
        ${buildPackages.perl}/bin/perl -w ${builder}
    else
      out=$develop pkgs=$developPkgs FLOX_RECURSIVE_LINK=1 \
        ${buildPackages.perl}/bin/perl -w ${builder}
    fi

    # Iterate over manifest builds creating closures for each build as
    # specified in the manifest.
    for build in ${builtins.toString manifestBuilds}; do
      tmppkgs=$(mktemp)
      ${buildPackages.jq}/bin/jq -c -r -f ${build_closures_jq} \
        --arg activationScripts ${activationScripts} \
        --arg build $build \
	--arg system ${targetPlatform.system} \
	${manifest} > $tmppkgs
      out=''${!build} pkgsPath=$tmppkgs FLOX_RECURSIVE_LINK=1 \
        ${buildPackages.perl}/bin/perl -w ${builder}
      rm $tmppkgs
    done

    eval "$postBuild"
  '')
