{
  coreutils,
  flox-activation-scripts,
  getopt,
  gnused,
  jq,
  procps,
  lib,
  nix,
  nixpkgsClone,
  runCommandLocal,
  writers,
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
  buildenv_nix_patch = ./buildenv.nix.patch;
  builder_pl_patch = ./builder.pl.patch;
  build_packages_jq = ./build-packages.jq;
  build_closures_jq = ./build-closures.jq;

in
  runCommandLocal
  "${pname}-${version}"
  {
    inherit coreutils getopt jq nix pname version;
    activationScripts = flox-activation-scripts;
  }
  ''
    mkdir -p "$out/bin" "$out/lib"
    cp ${buildenv} "$out/bin/buildenv"
    substituteAllInPlace "$out/bin/buildenv"
    cp ${pkgdb} "$out/bin/pkgdb"
    substituteAllInPlace "$out/bin/pkgdb"
    cp --no-preserve=mode ${nixpkgsBuildenvRoot}/default.nix "$out/lib/buildenv.nix"
    (cd $out/lib && exec patch -p2 < ${buildenv_nix_patch})
    cp --no-preserve=mode ${nixpkgsBuildenvRoot}/builder.pl "$out/lib/builder.pl"
    (cd $out/lib && exec patch -p2 < ${builder_pl_patch})
    cp ${build_packages_jq} "$out/lib/build-packages.jq"
    cp ${build_closures_jq} "$out/lib/build-closures.jq"
  ''
