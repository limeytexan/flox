{
  coreutils,
  flox-activation-scripts,
  gnused,
  jq,
  procps,
  lib,
  nix,
  runCommandLocal,
  writers,
}: let
  pname = "flox-buildenv";
  version = "0.0.1";
  buildenv = (
    writers.writeBash "buildenv" (
      builtins.readFile ./buildenv.bash
    )
  );
  buildenv_nix = ./buildenv.nix;
  builder_pl = ./builder.pl;
  build_packages_jq = ./build-packages.jq;
  build_closures_jq = ./build-closures.jq;

  # Wrap the script with a shebang.
#  activate = writers.writeBash "activate" "${flox-activation-scripts}/activate";

in
  runCommandLocal
  "${pname}-${version}"
  {
    inherit coreutils jq nix pname version;
    activationScripts = flox-activation-scripts;
  }
  ''
    mkdir -p "$out/bin" "$out/lib"
    cp ${buildenv} "$out/bin/buildenv"
    substituteAllInPlace "$out/bin/buildenv"
    cp ${buildenv_nix} "$out/lib/buildenv.nix"
    cp ${builder_pl} "$out/lib/builder.pl"
    cp ${build_packages_jq} "$out/lib/build-packages.jq"
    cp ${build_closures_jq} "$out/lib/build-closures.jq"
  ''
