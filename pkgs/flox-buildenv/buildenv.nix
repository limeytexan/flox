{ activationScripts
, builder ? "@out@/lib/builder.pl"
, coreutils ? "@coreutils@"
, defaultEnvrc ? "@defaultEnvrc@"
, manifest
, name
}:

let
  # A helpful library function copied from nixpkgs/lib/attrsets.nix.
  foldlAttrs = f: init: set:
    builtins.foldl'
      (acc: name: f acc name set.${name})
      init
      (builtins.attrNames set);

  # The system we're building for.
  system = builtins.currentSystem;

  # Copy manifest file into the store for access within derivations.
  manifestLock = /. + manifest;

  # Parse the manifest file.
  manifestLockData = builtins.fromJSON (builtins.readFile manifest);
  manifestData = manifestLockData.manifest;

  build = if (builtins.hasAttr "build" manifestData) then
    manifestData.build else {};
  hook = if (builtins.hasAttr "hook" manifestData) then
    manifestData.hook else {};
  profile = if (builtins.hasAttr "profile" manifestData) then
    manifestData.profile else {};
  vars = if (builtins.hasAttr "vars" manifestData) then (
    builtins.toFile "envrc-vars" (
      foldlAttrs (
        acc: n: v: acc + "export ${n}=\"${v}\"\n"
      ) "" manifestData.vars
    )
  ) else null;

  # Calculate floxenv outputs.
  floxenvOutputs = [ "out" "develop" ] ++ (
    builtins.map (x: "build-${x}") (builtins.attrNames build)
  );

  # Calculate inputSrcs by noting all storePaths for this system's
  # packages found in the packages list.
  inputSrcs = builtins.concatMap (
    package: if package.system == system then (
      if (builtins.hasAttr "outputs" package) then (
        # TODO: filter by outputsToInstall?
        builtins.attrValues package.outputs
      ) else []
    ) else []
  ) manifestLockData.packages;

  createManifestChunks = [
    # static chunks
    ''
      TIMEFORMAT='manifest package built in %R seconds'
      time {
      export PATH="${coreutils}/bin''${PATH:+:}''${PATH}"
      mkdir -p $out/activate.d
      cp --no-preserve=mode ${manifestLock} $out/manifest.lock
      cp --no-preserve=mode ${defaultEnvrc} $out/activate.d/envrc
    ''
    # [vars] section
    (
      if vars == null then "" else ''
        cat ${vars} >> $out/activate.d/envrc
      ''
    )
    # [hook] section
    (
      if (builtins.hasAttr "on-activate" hook) then ''
        cp ${builtins.toFile "hook-on-activate" hook."on-activate"} $out/activate.d/hook-on-activate
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
  ) ++ [
    # conclude time block
    ''
      }
    ''
  ];

  createManifestScript = builtins.toFile "create-manifest-script" (
    builtins.concatStringsSep "" createManifestChunks
  );

  manifestPackage = builtins.trace createManifestScript builtins.derivation {
    name = "manifest";
    inherit system;
    builder = "/bin/sh";
    args = [ "-eux" createManifestScript ];
  };

in builtins.derivation {
  name = "floxenv-${name}";
  outputs = builtins.trace (builtins.concatStringsSep " " floxenvOutputs) floxenvOutputs;

  # Pull in external attributes and those calculated above.
  inherit activationScripts builder inputSrcs manifestPackage system;

  # If the special attribute __structuredAttrs is set to true, the
  # other derivation attributes are serialised in JSON format and
  # made available to the builder via the file .attrs.json in the
  # builder’s temporary directory. This obviates the need for
  # passAsFile since JSON files have no size restrictions, unlike
  # process environments.
  __structuredAttrs = true;
}
