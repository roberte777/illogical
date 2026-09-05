{
  description = "illogical — a persistent terminal multiplexer powered by libghostty";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems.url = "github:nix-systems/default";

    # Zig toolchain. Pinned to the version required by the vendored ghostty
    # checkout (vendor/ghostty/build.zig.zon :: minimum_zig_version).
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        systems.follows = "systems";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    systems,
    zig,
    ...
  }: let
    inherit (nixpkgs) lib;
    eachSystem = lib.genAttrs (import systems);
    pkgsFor = system: nixpkgs.legacyPackages.${system};

    # Keep in sync with vendor/ghostty's minimum_zig_version.
    zigVersion = "0.16.0";
  in {
    devShells = eachSystem (system: let
      pkgs = pkgsFor system;
      zigPkg = zig.packages.${system}.${zigVersion};
    in {
      default = pkgs.mkShell {
        name = "illogical";

        packages =
          [
            zigPkg
          ]
          ++ (with pkgs; [
            # Build glue
            just
            pkg-config

            # Repo hygiene
            alejandra # nix formatter
            git
          ])
          ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin (with pkgs; [
            # macOS client tooling. Xcode itself is NOT provided by nix —
            # it must be installed from the App Store / developer.apple.com,
            # because Swift 6 + xcodebuild are not packaged in nixpkgs.
            xcodegen
            swift-format
            swiftlint
          ]);

        shellHook = ''
          # `nix develop <path>` keeps the caller's cwd, so derive the root
          # from git rather than $PWD.
          ILLOGICAL_ROOT="''${ILLOGICAL_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
          export ILLOGICAL_ROOT

          # Keep zig's global cache inside the repo so `nix develop` sessions
          # and CI share one warm cache and `just clean` can nuke it.
          export ZIG_GLOBAL_CACHE_DIR="$ILLOGICAL_ROOT/.zig-cache/global"
          export ZIG_LOCAL_CACHE_DIR="$ILLOGICAL_ROOT/.zig-cache/local"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

          if [ ! -e "$ILLOGICAL_ROOT/vendor/ghostty/build.zig" ]; then
            echo "illogical: vendor/ghostty is empty."
            echo "           run: git submodule update --init --recursive"
          fi
        '';
      };
    });

    formatter = eachSystem (system: (pkgsFor system).alejandra);
  };

  nixConfig = {
    # ghostty publishes libghostty-vt builds here; harmless if unused.
    extra-substituters = ["https://ghostty.cachix.org"];
    extra-trusted-public-keys = [
      "ghostty.cachix.org-1:QB389yTa6gTyneehvqG58y0WnHjQOqgnA+wBnpWWxns="
    ];
  };
}
