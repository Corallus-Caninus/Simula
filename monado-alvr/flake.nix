{
  description = "Monado-ALVR: Monado fork integrating the ALVR streaming server, for Quest 3 + Simula";

  inputs = {
    # Recent nixpkgs (rust >= 1.88 required by ALVR monado branch)
    nixpkgs.url = "github:NixOS/nixpkgs/b7c2ada94fe99c15b0dbcf4d11fd7850b957a436";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.cudaSupport = true;
      };

      # Pinned upstream sources (revs are fixed; tarballs are stable per rev).
      monadoAlvrSrc = builtins.fetchTarball {
        url = "https://codeload.github.com/alvr-org/Monado-ALVR/tar.gz/99384cb728f30c1d7d20a40c3bfec702e2f8978c";
        sha256 = "0ajxl6vyanrflv1lwbrj42yyp915417khgzw2v2vfyq9nz9g20j6";
      };
      alvrMonadoSrc = builtins.fetchTarball {
        url = "https://codeload.github.com/alvr-org/ALVR/tar.gz/5d45a6dcd9a5ae3df7c60c6a1282fb52140346da";
        sha256 = "1xlx2accc7k4g3rl8p7dq3ngmwpgj9zhigv1p22w1wjs4ilzhavk";
      };
      alvrRenderSrc = builtins.fetchTarball {
        url = "https://codeload.github.com/The-personified-devil/alvr_render/tar.gz/ecb281249b6900ec6ceb6e0570be5100533c706a";
        sha256 = "0886arsymdrdfw960b28l48k4nj83xkdg1rby7frkppv201bh9j7";
      };
    in
    {
      packages.${system} = rec {
        alvr-server-core = pkgs.callPackage ./alvr-server-core.nix { src = alvrMonadoSrc; };
        monado-alvr = pkgs.callPackage ./monado-alvr.nix {
          src = monadoAlvrSrc;
          alvrRenderSrc = alvrRenderSrc;
          inherit alvr-server-core;
        };
        default = monado-alvr;
      };
    };
}
