{
  # TODO: Use nixpkgs 22.05?
  iohkNix ?
    import (
      builtins.fetchTarball "https://github.com/input-output-hk/iohk-nix/archive/edb2d2df2ebe42bbdf03a0711115cf6213c9d366.tar.gz"
    ) {},
  pkgs ?
    import ( # A recent `master` (2022 May) for a newer `fourmolu`
      builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/adfcb57e27981eea2c6f3d0cc609119d6186dfaa.tar.gz"
    ) {
      overlays = iohkNix.overlays.crypto;
    },
  haskellCompiler ? "ghc8107",
}:
with pkgs; let
  haskellEnv = with haskell.packages.${haskellCompiler}; [
    ghc
    cabal-install
    (fourmolu_0_6_0_0.override {
      Cabal = Cabal_3_6_3_0;
      ghc-lib-parser = ghc-lib-parser_9_2_2_20220307;
    })
    hlint
    haskell-language-server
  ];
  libraries = [
    libsodium-vrf
    lzma
    pkgconfig
    secp256k1
    zlib
  ];
  certFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
in
  mkShell {
    name = "plutonomy";
    buildInputs = haskellEnv ++ libraries;
    GIT_SSL_CAINFO = certFile;
    NIX_SSL_CERT_FILE = certFile;
  }
