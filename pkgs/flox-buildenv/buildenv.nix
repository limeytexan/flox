# buildEnv creates a tree of symlinks to the specified paths.  This is
# a fork of the hardcoded buildEnv in the Nix distribution.

{ buildPackages, runCommandNoCCLocal, lib, substituteAll }:

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
    # Copy manifest file to store for access within derivations.
    manifestFile = /. + manifest;
    # Unlike the nixpkgs buildEnv, the Flox one has multiple outputs,
    # the usual builtins.buildenv() output, a "develop" output, and
    # a runtime closure for each of the manifest builds.
    manifestBuilds = if manifest == "" then [] else (
      let _manifest = builtins.fromJSON (builtins.readFile manifest);
      in builtins.attrNames _manifest.manifest.build
    );
    runtimePkgPrefix = "build_";
    manifestBuildRuntimeOutputs = map (s: runtimePkgPrefix + s) manifestBuilds;
    outputs = ["out" "develop"] ++ manifestBuildRuntimeOutputs;

    userActivationScripts = let
      defaultEnvrc = ''
        # Default environment variables
        export SSL_CERT_FILE="''${SSL_CERT_FILE:-${buildPackages.cacert}/etc/ssl/certs/ca-bundle.crt}"
        export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-''${SSL_CERT_FILE}}"
      '' + lib.optionalString buildPackages.hostPlatform.isLinux ''
        export LOCALE_ARCHIVE="''${LOCALE_ARCHIVE:-${buildPackages.glibcLocalesUtf8}/lib/locale/locale-archive}"
      '' + lib.optionalString buildPackages.hostPlatform.isDarwin ''
        export NIX_COREFOUNDATION_RPATH="''${NIX_COREFOUNDATION_RPATH:-"${buildPackages.darwin.CF}/Library/Frameworks"}"
        export PATH_LOCALE="''${PATH_LOCALE:-${buildPackages.darwin.locale}/share/locale}"
      '' + ''
        # Static environment variables
      '';
    in runCommandNoCCLocal "activation-scripts" {
      preferLocalBuild = true;
      allowSubstitutes = false;
    } ''
      mkdir -p $out/activate.d
      echo -n '${defaultEnvrc}' > $out/activate.d/envrc
      set -x
      time ${buildPackages.jq}/bin/jq -r '
        .manifest.vars |
        to_entries[] |
        "export \(.key)=\"\(.value)\""
      ' ${manifestFile} >> $out/activate.d/envrc
      time ${buildPackages.jq}/bin/jq -r '
        if (.manifest.hook | has("on-activate")) then
          .manifest.hook["on-activate"]
        else empty end
      ' ${manifestFile} > $out/activate.d/hook-on-activate
      [ -s $out/activate.d/hook-on-activate ] || rm $out/activate.d/hook-on-activate
      for i in common bash fish tcsh zsh; do
        time ${buildPackages.jq}/bin/jq -r --arg section $i '
          if (.manifest.profile | has($section)) then
            .manifest.profile[$section]
          else empty end
        ' ${manifestFile} > $out/activate.d/profile-$i
        [ -s $out/activate.d/profile-$i ] || rm $out/activate.d/profile-$i
      done
      set +x
    '';

in
runCommandNoCCLocal name
  rec {
    inherit manifest ignoreCollisions checkCollisionContents passthru
            meta pathsToLink extraPrefix postBuild
            nativeBuildInputs buildInputs outputs;
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
    preferLocalBuild = true;
    allowSubstitutes = false;
    # Nix "*Path" environment variables are automatically created by
    # way of the derivation `passAsFile` attribute as described in:
    #
    # https://nix.dev/manual/nix/2.18/language/advanced-attributes#adv-attr-passAsFile
    #
    # The following causes `pkgsPath` to always be set.
    passAsFile = [ "pkgs" ];
  }
  ''
    ${buildPackages.perl}/bin/perl -w ${builder}

    # The `builder.pl` script expects to receive the list of packages by
    # way of one of the `pkgsPath` or `pkgs` environment variables. Explicitly
    # set `pkgsPath` to pass our modified when building flox environments.

    # Assert $pkgsPath is set.
    if [ -z "$pkgsPath" ]; then
      echo "Error: \$pkgsPath is not set." >&2
      exit 1
    fi

    # Add the activation scripts package to the list of packages and
    # build the "develop" output.
    tmppkgs=$(mktemp)
    time ${buildPackages.jq}/bin/jq -c -r '
      . + [
        {
          "paths": [ "${activationScripts}" ],
          "priority": 1
        },
        {
          "paths": [ "${userActivationScripts}" ],
          "priority": 1
        }
      ]
    ' $pkgsPath > $tmppkgs
    out=$develop pkgsPath=$tmppkgs FLOX_RECURSIVE_LINK=1 \
      ${buildPackages.perl}/bin/perl -w ${builder}

    # Iterate over manifest builds creating closures for each build as
    # specified in the manifest.
    for buildRuntimeOutput in ${builtins.toString manifestBuildRuntimeOutputs}; do
      build="''${buildRuntimeOutput#${runtimePkgPrefix}}"
      time ${buildPackages.jq}/bin/jq -c -r -f ${build_closures_jq} \
        --arg activationScripts ${activationScripts} \
        --arg userActivationScripts ${userActivationScripts} \
        --arg build $build \
        --arg system ${builtins.currentSystem} \
        ${manifestFile} > $tmppkgs
      out="''${!buildRuntimeOutput}" pkgsPath=$tmppkgs FLOX_RECURSIVE_LINK=1 \
        ${buildPackages.perl}/bin/perl -w ${builder}
    done

    # Clean up.
    rm $tmppkgs

    eval "$postBuild"
  '')
