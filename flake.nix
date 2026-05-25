{
  description = "Dust — a high-availability, decentralized file storage system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    let
      # The NixOS module is platform-independent; expose it at the top
      # level so users can `imports = [ inputs.dust.nixosModules.default ];`
      # without picking a system first.
      nixosModule = import ./nix/module.nix;
    in
    {
      nixosModules = {
        default = nixosModule;
        dust = nixosModule;
      };

      # Overlay that adds the daemon + CLI under `pkgs.dust` / `pkgs.dustctl`
      # so users who import the overlay can refer to the packages naturally
      # in their NixOS configuration.
      overlays.default = final: prev:
        let
          beamPackages = final.beam28Packages or final.beamPackages;
          tsnetSidecar = final.callPackage ./nix/tsnet-sidecar.nix { };
        in
        {
          dust = final.callPackage ./nix/daemon.nix {
            inherit beamPackages tsnetSidecar;
          };

          dustctl = final.callPackage ./nix/cli.nix {
            inherit beamPackages;
          };
        };
    } // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

        beamPackages = pkgs.beam28Packages or pkgs.beamPackages;
      in
      {
        packages = {
          default = pkgs.dust;
          dust = pkgs.dust;
          dustctl = pkgs.dustctl;
          tsnet-sidecar = pkgs.callPackage ./nix/tsnet-sidecar.nix { };
        };

        apps = {
          default = {
            type = "app";
            program = "${pkgs.dust}/bin/dust";
          };
          dust = {
            type = "app";
            program = "${pkgs.dust}/bin/dust";
          };
          dustctl = {
            type = "app";
            program = "${pkgs.dustctl}/bin/dustctl";
          };
        };

        # Dev shell — mirrors the previous `shell.nix`. Kept as the source
        # of truth; `shell.nix` is now a thin flake-compat shim.
        devShells.default = pkgs.mkShell {
          name = "dust-dev";

          buildInputs = [
            beamPackages.erlang
            beamPackages.elixir_1_19

            pkgs.go
            pkgs.rustc
            pkgs.cargo
            pkgs.rustfmt
            pkgs.clippy

            pkgs.cmake
            pkgs.gcc
            pkgs.gnumake
            pkgs.pkg-config

            pkgs.git

            pkgs.snappy
            pkgs.openssl
            pkgs.zlib
            pkgs.zstd
            pkgs.lz4
            pkgs.bzip2
            pkgs.xz
          ];

          shellHook = ''
            export MIX_HOME="$PWD/.mix"
            export HEX_HOME="$PWD/.hex"
            export PKG_CONFIG_PATH="${pkgs.snappy.dev}/lib/pkgconfig:${pkgs.openssl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"

            echo "Dust dev shell"
            echo "  erlang : $(erl -eval 'io:format(\"~s\", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null)"
            echo "  elixir : $(elixir --short-version 2>/dev/null)"
            echo "  go     : $(go version 2>/dev/null | cut -d' ' -f3)"
            echo "  rustc  : $(rustc --version 2>/dev/null | cut -d' ' -f2)"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;

        checks = {
          inherit (self.packages.${system}) dust dustctl tsnet-sidecar;
        };
      });
}
