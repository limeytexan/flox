# buildEnv creates a tree of symlinks to the specified paths.  This is
# a fork of the hardcoded buildEnv in the Nix distribution.

{ buildPackages, runCommand, lib, substituteAll }:

let
  builder = substituteAll {
    src = ./builder.pl;
    inherit (builtins) storeDir;
  };
in

lib.makeOverridable
({ name

, # The path to the flox "interpreter" package.
    interpreter

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

runCommand name
  rec {
    inherit manifest ignoreCollisions checkCollisionContents passthru
            meta pathsToLink extraPrefix postBuild
            nativeBuildInputs buildInputs;

    # Unlike the nixpkgs buildEnv, the Flox one has two outputs.
    outputs = ["out" "develop"];

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

    # The develop output adds a single package, the interpreter.
    # I'm sure a Nix professional could make this more elegant
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
        paths = [interpreter];
        priority = 1;
      }
    ]);

    preferLocalBuild = true;
    allowSubstitutes = false;
    # XXX: The size is somewhat arbitrary
    passAsFile = if builtins.stringLength pkgs >= 128*1024 then [ "pkgs" "developPkgs" ] else [ ];
  }
  ''
    ${buildPackages.perl}/bin/perl -w ${builder}
    if [ -n "$developPkgsPath" ]; then
      out=$develop pkgsPath=$developPkgsPath ${buildPackages.perl}/bin/perl -w ${builder}
    else
      out=$develop pkgs=$developPkgs ${buildPackages.perl}/bin/perl -w ${builder}
    fi
    ls -ld $out $develop
    eval "$postBuild"
  '')
