# Flox environment builder

The files in this directory are copied from nixpkgs:pkgs/build-support/buildenv
with minimal modifications as denoted by the <flox> </flox> comment delimiters.

While we await examples of the final `manifest.lock` format I've rigged up a
prototype that parses/processes the `nix profile` `manifest.json` schema instead.

To test:

```
nix build .#flox-buildenv
result/bin/buildenv <path/to/manifest.json>
```
