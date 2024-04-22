{
  coreutils,
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

  # Extract the bash "activate" script from the rust source code.
  # Blech, but hey it works for a demo.
  activate_bash = runCommandLocal "activate" {} ''
    cat > $out <<EOF
    export _coreutils="@coreutils@"
    export _gnused="@gnused@"
    export _procps="@procps@"
    EOF
    awk 'BEGIN {p=0} /^\)_";/ {exit} (p) {print} /const ACTIVATE_SCRIPT = R"_\(/ {p=1}' \
      ${../../pkgdb/src/buildenv/realise.cc} >> $out
  '';

  # Wrap the script with a shebang.
  activate = writers.writeBash "activate" activate_bash;

  # Construct the flox "interpreter" package containing all files required
  # for activating a flox environment. This won't be nearly so complicated
  # once we refactor the repository to put these all in a single directory.
  interpreter =
    runCommandLocal "interpreter" {
      inherit coreutils gnused procps;
    } ''
      mkdir -p $out/bin
      cp ${activate} $out/bin/activate
      substituteAllInPlace "$out/bin/activate"
      cp -r ${../../pkgdb/src/buildenv/assets/etc} $out/etc
      chmod -R +w $out/etc
      rm -f $out/etc/profile.d/.gitignore
      mkdir -p $out/etc/activate.d
      cp -r ${../../pkgdb/src/buildenv/assets/activate.d}/* $out/etc/activate.d
    '';
in
  runCommandLocal
  "${pname}-${version}"
  {
    inherit coreutils interpreter jq nix pname version;
  }
  ''
    mkdir -p "$out/bin" "$out/lib"
    cp ${buildenv} "$out/bin/buildenv"
    substituteAllInPlace "$out/bin/buildenv"
    cp ${buildenv_nix} "$out/lib/buildenv.nix"
    cp ${builder_pl} "$out/lib/builder.pl"
    cp ${build_packages_jq} "$out/lib/build-packages.jq"
  ''
