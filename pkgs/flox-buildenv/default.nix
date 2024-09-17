{
  cacert,
  darwin,
  coreutils,
  flox-activation-scripts,
  getopt,
  glibcLocalesUtf8,
  gnused,
  jq,
  procps,
  lib,
  nix,
  nixpkgsClone,
  perl,
  runCommandNoCC,
  stdenv,
  writers,
  writeText,
}: let
  pname = "flox-buildenv";
  version = "0.0.1";
  nixpkgsBuildenvRoot = nixpkgsClone + "/pkgs/build-support/buildenv";
  buildenv = (
    writers.writeBash "buildenv" (
      builtins.readFile ./buildenv.bash
    )
  );
  pkgdb = (
    writers.writeBash "pkgdb" (
      builtins.readFile ./pkgdb.bash
    )
  );
  buildenv_nix = ./buildenv.nix;
  buildenv_nix_patch = ./buildenv.nix.patch;
  builder_pl_patch = ./builder.pl.patch;
  build_packages_jq = ./build-packages.jq;
  build_closures_jq = ./build-closures.jq;
  mkFloxEnvDerivation_jq = ./mkFloxEnvDerivation.jq;
  activationScripts = flox-activation-scripts;
  activationScriptsDrv = "FOORBAR";
  builderDrv = "FOOBAR";
  defaultEnvrc = writeText "default.envrc" (''
    # Default environment variables
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-''${SSL_CERT_FILE}}"
  '' + lib.optionalString stdenv.isLinux ''
    export LOCALE_ARCHIVE="''${LOCALE_ARCHIVE:-${glibcLocalesUtf8}/lib/locale/locale-archive}"
  '' + lib.optionalString stdenv.isDarwin ''
    export NIX_COREFOUNDATION_RPATH="''${NIX_COREFOUNDATION_RPATH:-"${darwin.CF}/Library/Frameworks"}"
    export PATH_LOCALE="''${PATH_LOCALE:-${darwin.locale}/share/locale}"
  '' + ''
    # Static environment variables
  '');

in
  runCommandNoCC
  "${pname}-${version}"
  {
    inherit coreutils getopt jq nix pname version
      activationScripts activationScriptsDrv builderDrv defaultEnvrc;
    # Substitutions for builder.pl.
    inherit (builtins) storeDir;
    perl = perl + "/bin/perl";
  }
  ''
    mkdir -p "$out/bin" "$out/lib"
    cp ${buildenv} "$out/bin/buildenv"
    substituteAllInPlace "$out/bin/buildenv"
    cp ${pkgdb} "$out/bin/pkgdb"
    substituteAllInPlace "$out/bin/pkgdb"
    #cp --no-preserve=mode ${nixpkgsBuildenvRoot}/default.nix "$out/lib/buildenv.nix"
    #(cd $out/lib && exec patch -p2 < ${buildenv_nix_patch})
    cp ${buildenv_nix} "$out/lib/buildenv.nix"
    cp --no-preserve=mode ${nixpkgsBuildenvRoot}/builder.pl "$out/lib/builder.pl"
    (cd $out/lib && exec patch -p2 < ${builder_pl_patch})
    chmod +x "$out/lib/builder.pl"
    substituteAllInPlace "$out/lib/builder.pl"
    cp ${build_packages_jq} "$out/lib/build-packages.jq"
    cp ${build_closures_jq} "$out/lib/build-closures.jq"
    cp ${mkFloxEnvDerivation_jq} "$out/lib/mkFloxEnvDerivation.jq"
  ''
