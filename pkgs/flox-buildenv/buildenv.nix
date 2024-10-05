{ coreutils ? "/nix/store/fh4107h5wf0ad7avarvhsdzcw7g2laq9-coreutils-full-9.5"
, defaultEnvrc ? "/nix/store/7mibq9n5zad7ndyl156dv8r764m5yc08-defaultEnvrc"
, manifest ? "/Users/brantley/.cache/flox/remote/limeytexan/default/.flox/env/manifest.lock"
}:

let
  # A helpful library function copied from nixpkgs/lib/attrsets.nix.
  foldlAttrs = f: init: set:
    builtins.foldl'
      (acc: name: f acc name set.${name})
      init
      (builtins.attrNames set);

  # Copy manifest file into the store for access within derivations.
  manifestLock = /. + manifest;

  # Parse the manifest file.
  manifestLockData = builtins.fromJSON (builtins.readFile manifest);
  manifestData = manifestLockData.manifest;

  vars = if (builtins.hasAttr "vars" manifestData) then
    ( foldlAttrs (acc: n: v: acc + "export ${n}=\"${v}\"\n") "" manifestData.vars )
    else "# No vars in manifest\n";

  build = if (builtins.hasAttr "build" manifestData) then
    manifestData.build else {};
  hook = if (builtins.hasAttr "hook" manifestData) then
    manifestData.hook else {};
  profile = if (builtins.hasAttr "profile" manifestData) then
    manifestData.profile else {};

  createManifestChunks = [
    # static chunks
    ''
      export PATH="${coreutils}/bin''${PATH:+:}''${PATH}"
      mkdir -p $out/activate.d
      cp --no-preserve=mode ${manifestLock} $out/manifest.lock
      cp --no-preserve=mode ${defaultEnvrc} $out/activate.d/envrc
    ''

    # [vars] appended to envrc
    (
      if (builtins.hasAttr "vars" manifestData) then (
        foldlAttrs (
          acc: n: v: acc + "export ${n}=\"${v}\"\n"
        ) "" manifestData.vars
      ) else ""
    )

    # [hook] section
    (
      if (builtins.hasAttr "on-activate" hook) then ''
        cp ${builtins.toFile "hook-on-activate" hook."on-activate"} \
          $out/activate.d/hook-on-activate
      '' else ""
    )

  ] ++ (

    # [profile] section
    builtins.map ( i:
      if (builtins.hasAttr i profile) then
        let f = builtins.toFile "profile-${i}" (builtins.getAttr i profile);
        in "cp ${f} $out/activate.d/profile-${i}\n"
      else ""
    ) [ "bash" "fish" "tcsh" "zsh" ]

  ) ++ (

    # [build] section
    builtins.map ( i:
      let b = builtins.getAttr i build;
      in (
        if (builtins.hasAttr "command" b) then (
          let f = builtins.toFile "build-${i}" (builtins.getAttr "command" b);
          in ''
            mkdir -p $out/package-builds.d
            cp ${f} $out/package-builds.d/${i}
          ''
        ) else ""
      )
    ) ( builtins.attrNames build )

  );

  createManifestScript = builtins.toFile "create-manifest-script" (
    builtins.concatStringsSep "" createManifestChunks
  );

  manifestPackage = builtins.trace createManifestScript builtins.derivation {
    name = "manifest";
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [ "-eux" createManifestScript ];
  };

in manifestPackage

/*
  # Generate the environment-specific "manifest" packages from the
  # manifest.lock file.
  manifestPackage = let
    envrc = fromFile defaultEnvrc + (
      if manifestData | hasAttr "vars" then (
	 manifestData.vars
	 ( attrNames manifestData.vars )
      ) else ""
    );
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
    '' + (
      if 
      manifestData 
      to_entries[] |
      "export \(.key)=\"\(.value)\""
    );

  in builtins.derivation {
    name = "manifest";
    system = builtins.currentSystem;
    inherit manifestData;
    builder = ./builder.pl;
    args = [ "manifest" ];
    inherit envrc;
  };

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


let
  outputs = [ $outputs ];
  outputSrc = /. + "$_tmpdir/outputs";
  # The builder is simply a shell script that copies the outputs to the
  # output names, eg "cp -a out \$out; cp -a develop \$develop; ...".
  builderCommands = "cd \${outputSrc}; " + (
    builtins.concatStringsSep "; " (
      map (output: "$_cp -a \${output} \\\$\${output}") outputs
    )
  );

in builtins.derivation {
  # The following are mandatory derivation attributes.
  name = "$name";
  system = "@system@";
  inherit outputs;
  # The "/bin/sh" link is provided by default in all build sandboxes.
  builder = "/bin/sh";
  args = [ "-eux" "-c" builderCommands ];
  # Declare all other input packages. Note that the use of "inputSrcs"
  # here is arbitrary, and could be any other attribute name.
  inputSrcs = map (x: builtins.storePath x) [
    ${inputSrcs[@]}
    $activationScripts
    $manifestPackage
  ];
}
*/
